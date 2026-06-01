import SwiftUI
import UIKit
import GhosttyTerminal
import OSLog
#if DEBUG
import TalkerCommonLogging
#endif

private let ptyLog = Logger(subsystem: "io.allsunday.motif", category: "PtyView")

extension Notification.Name {
    /// Posted (trailing-debounced) after the active PTY applies output, so the
    /// host can re-evaluate cursor-dependent layout (e.g. the keyboard lift).
    /// `userInfo["ptyID"]` carries the PTY id.
    static let motifTerminalDidRender = Notification.Name("motifTerminalDidRender")
}

#if DEBUG
/// DEBUG-only: route libghostty-spm's `TerminalDebugLog` into
/// TalkerCommonLogging so metric/lifecycle/action events land in
/// `Documents/logs/<bundle>.log` alongside the rest of our diagnostics.
/// Categories deliberately exclude `.render` and `.output` — they fire
/// per-frame / per-byte and would drown the file. Initialized lazily on
/// the first Ghostty coordinator so non-Ghostty sessions pay nothing.
private let ghosttyDebugLogOnce: Void = {
    TerminalDebugLog.sink = { message in
        infoLog("[Ghostty] \(message)")
    }
    TerminalDebugLog.enable([.lifecycle, .metrics, .actions])
}()
#endif

/// One-shot async gate: callers `await wait()` until `signal()` fires, then
/// return immediately forever after. `signal()` is idempotent and wakes every
/// pending waiter. `signal(after:)` arms a backstop timer that force-opens the
/// gate if nothing has signaled it by the deadline — so a caller can't wedge
/// on a gate that never legitimately opens.
///
/// MainActor-isolated: waiters and the signaller share the same isolation, so
/// the latch + continuation list need no locking. `wait()` parks on a plain
/// `CheckedContinuation` (no per-waiter timeout), so there's no "cancelled task
/// leaves a continuation un-resumed" hazard — the deadline path opens the gate
/// for everyone via `signal()` rather than releasing one waiter.
@MainActor
final class OneShotGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var backstop: Task<Void, Never>?

    var isOpen: Bool { open }

    /// Suspend until the gate opens; returns immediately if already open.
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Open the gate, wake all waiters, and cancel any pending backstop.
    /// Idempotent — the first caller (real signal or the backstop) wins.
    func signal() {
        guard !open else { return }
        open = true
        backstop?.cancel()
        backstop = nil
        let pending = waiters
        waiters = []
        for w in pending { w.resume() }
    }

    /// Arm a backstop that force-opens the gate after `delay` unless `signal()`
    /// happens first. `onTimeout` runs only if the backstop actually fires (for
    /// diagnostics). No-op if the gate is already open or a backstop is armed.
    func signal(after delay: Duration, onTimeout: (() -> Void)? = nil) {
        guard !open, backstop == nil else { return }
        backstop = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.open, !Task.isCancelled else { return }
            onTimeout?()
            self.signal()
        }
    }
}

/// Motif-specific UITerminalView subclass. It suppresses ghostty's
/// bundled chip bar so Motif's BottomInputBar stays the single input
/// authority; touch and first-responder behavior otherwise stays with
/// Ghostty's default implementation.
final class MotifTerminalView: UITerminalView {
    override var inputAccessoryView: UIView? { nil }

    /// Points from the bottom of the cursor cell to the bottom edge of the view.
    /// Large when the prompt sits near the top with blank rows below (fresh
    /// shell), ~0 once output fills the screen. nil if the surface/caret isn't
    /// ready. Reads the cursor cell via the public UITextInput `caretRect`,
    /// which (with no marked IME text) resolves to libghostty's `imePoint` in
    /// this view's coordinate space (points, top-left origin).
    func cursorDistanceFromBottom() -> CGFloat? {
        guard bounds.height > 0 else { return nil }
        let caret = caretRect(for: endOfDocument)
        guard caret.height > 0, caret.maxY.isFinite, caret.maxY > 0 else { return nil }
        return max(0, bounds.height - caret.maxY)
    }
}

/// libghostty-vt backed PTY surface. Wraps GhosttyTerminal's `UITerminalView`
/// + `InMemoryTerminalSession`: server PTY bytes -> `session.receive`,
/// terminal output bytes -> `client.write`, grid resize -> `client.resize`.
///
/// FR is owned by UIKit/Ghostty's default responder handling.
struct GhosttyPtyTerminal: UIViewRepresentable {
    let ptyID: String
    let initialCols: UInt16
    let initialRows: UInt16
    let client: MotifClient
    let terminals: TerminalRegistry

    func makeCoordinator() -> Coordinator {
        Coordinator(runtime: terminals.runtime(client: client, ptyID: ptyID))
    }

    func makeUIView(context: Context) -> MotifTerminalView {
        context.coordinator.runtime.viewForAttachment()
    }

    func updateUIView(_ uiView: MotifTerminalView, context: Context) {
        // Configuration is set once in attach(to:); grid metrics flow
        // through the in-memory session's resize callback, output bytes
        // through the coordinator pump. Focus is Ghostty/UIKit default behavior.
    }

    @MainActor
    final class Coordinator: NSObject {
        let runtime: PtyTerminalRuntime

        init(runtime: PtyTerminalRuntime) {
            self.runtime = runtime
            super.init()
        }
    }
}

/// One retained Ghostty runtime per PTY. SwiftUI may destroy and recreate the
/// `UIViewRepresentable` when switching tabs, but the terminal surface state
/// must survive that churn. The runtime owns the view/session/controller and
/// starts its output pump only while this PTY is the active terminal tab.
@MainActor
final class PtyTerminalRuntime {
    let client: MotifClient
    let ptyID: String
    let terminals: TerminalRegistry

    private let view = MotifTerminalView(frame: .zero)
    private let controller = TerminalController()
    private lazy var session: InMemoryTerminalSession = makeSession()
    private var pumpTask: Task<Void, Never>?
    private var configured = false
    private var streaming = false
    /// Whether this runtime's stream is *exclusive* — i.e. opening it closes the
    /// other PTY sockets (single-active mode). False in background mode, where
    /// several PTYs stream at once. Carried into `activatePtyStream` from
    /// `startPump` and on `reactivate()` after a reconnect.
    private var exclusive = true
    private var disposed = false
    private var lastSize: (cols: UInt16, rows: UInt16) = (0, 0)

    /// `client.resize` trailing-debounce window — collapses libghostty's burst
    /// of first-attach reflows into one final resize. See `handleResize`.
    private static let gridResizeDebounceMs = 50
    /// `.motifTerminalDidRender` trailing-debounce window. See `scheduleRenderNotify`.
    private static let renderNotifyDebounceMs = 80
    /// Backstop for `firstOpenGate`: force-open if the surface never settles.
    private static let gridSettleBackstop: Duration = .seconds(10)

    /// One-shot gate for the *first* `/pty` stream open. The libghostty surface
    /// sizes its terminal core only as it lays out, churning through several
    /// grids in a few ms (0×0 → 32×11 → 54×43 → 54×35). Opening the cold stream
    /// during that churn lets the server's VT snapshot — which is laid out for
    /// the final grid (width-exact box drawing, absolute cursor `ESC[r;cH`) —
    /// get fed into a still-resizing terminal, where it wraps/scrolls wrong and
    /// the later reflow can't undo it (hard `\r\n` wraps don't re-merge). So we
    /// hold the first open until the grid settles AND that size has been sent to
    /// the server (`client.resize`), guaranteeing the snapshot is generated at —
    /// and fed into — the right grid. `handleResize`'s settled resize opens it;
    /// `startPump` arms a ~10s backstop so a surface that never lays out can't
    /// wedge the open forever. Only gates the first open — once open, warm
    /// reactivate / tab re-switch returns from `wait()` instantly; later live
    /// resizes flow through `handleResize` as usual.
    private let firstOpenGate = OneShotGate()
    /// Trailing-edge debounce for `client.resize`. On first attach,
    /// libghostty's grid reflows three times in ~10ms: ghostty's own
    /// default size on surface create, then `synchronizeMetrics` from
    /// `didMoveToWindow`'s `DispatchQueue.main.async` (before SwiftUI
    /// settles bounds), then `synchronizeMetrics` from `layoutSubviews`
    /// once the VStack has actually pushed the BottomInputBar in. Each
    /// reflow SIGWINCHes the shell and redraws the prompt — visible as
    /// the content "jittering up and down" the user reports. Coalescing
    /// inside 50ms collapses all three into one final resize.
    private var pendingResize: Task<Void, Never>?
    /// Trailing-edge debounce for the `.motifTerminalDidRender` post. Output
    /// arrives byte-burst by byte-burst; coalescing inside ~80ms keeps the
    /// host's cursor-driven relayout to a few ticks per second instead of one
    /// per chunk.
    private var pendingRenderNotify: Task<Void, Never>?

    init(client: MotifClient, ptyID: String, terminals: TerminalRegistry) {
        self.client = client
        self.ptyID = ptyID
        self.terminals = terminals
        #if DEBUG
        _ = ghosttyDebugLogOnce
        #endif
    }

    func viewForAttachment() -> MotifTerminalView {
        prepare()
        if view.superview != nil {
            view.removeFromSuperview()
        }
        return view
    }

    func prepare() {
        configureIfNeeded()
    }

    func setStreaming(_ active: Bool, exclusive: Bool) {
        guard !disposed else { return }
        configureIfNeeded()
        // The exclusivity can change without the on/off state changing (e.g. the
        // active tab going from single-active to background mode). Record it so a
        // later reactivate uses the right policy, but only (re)issue the open
        // when streaming actually toggles on — an already-open stream doesn't
        // need re-opening just because the flag flipped.
        self.exclusive = exclusive
        guard streaming != active else { return }
        streaming = active
        if active {
            startPump()
        } else {
            stopPump()
        }
    }

    /// Re-open this PTY's `/pty/<id>` substream on the current (post-reconnect)
    /// RpcClient without disturbing the live pump. The pump is still parked on
    /// the same output channel (MotifClient keeps channels across an
    /// involuntary drop), so we only need to reactivate the server-side
    /// substream — seeded with the carried byte cursor, it replays just the
    /// missed delta into the existing surface. No-op unless this PTY is the
    /// streaming (active) tab.
    func reactivate() {
        guard streaming, !disposed else { return }
        let client = self.client
        let ptyID = self.ptyID
        let exclusive = self.exclusive
        Task { await client.activatePtyStream(ptyID: ptyID, exclusive: exclusive) }
    }

    private func makeSession() -> InMemoryTerminalSession {
        let client = self.client
        let ptyID = self.ptyID
        return InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in
                    await client.write(ptyID: ptyID, data: data)
                }
            },
            resize: { [weak self] viewport in
                Task { @MainActor in
                    self?.handleResize(viewport)
                }
            }
        )
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

        // Expose this view to BottomInputBar's Ctrl/Alt buttons so they can
        // drive libghostty's sticky-modifier state machine. Registration
        // installs a change handler that re-renders any host UI mirroring the
        // sticky state.
        terminals.register(view, ptyID: ptyID)

        // libghostty's UITerminalView.didMoveToWindow forces the controller's
        // color scheme to the *system* appearance on every (re)attach — which
        // happens on every tab switch and would clobber an explicit Light/Dark
        // choice. The attach handler fires right after that, so we re-impose
        // our font + theme there. (Also re-applies once the surface exists.)
        view.windowAttachmentHandler = { [weak self] attached in
            guard attached else { return }
            self?.applyTerminalSettings()
        }

        // Claim PTY primary for this client when the surface gains focus, so
        // the shared master grid resizes to *this* device. Routes through
        // `view.activate` (server-side `mark_primary`) the same way a tab tap
        // does — focusing to type is as much an "I'm driving" signal as
        // switching tabs, and without it a focused terminal can keep rendering
        // at another client's width. See `terminalDidChangeFocus`.
        view.delegate = self

        // Pick up the current global font size + theme before the surface
        // renders its first frame.
        applyTerminalSettings()

        // The stream is controlled by setStreaming(_:). Inactive tabs retain
        // this Ghostty surface but do not subscribe to server output.
    }

    /// Push the registry's current font size + color scheme into this
    /// terminal's controller. Live across open surfaces; safe to call before
    /// the surface is attached (the controller stores it for surface creation).
    func applyTerminalSettings() {
        guard !disposed else { return }
        controller.setColorScheme(terminals.ptyColorScheme)
        controller.setTerminalConfiguration(
            TerminalConfiguration().fontSize(terminals.ptyFontSize)
        )
    }

    private func handleResize(_ viewport: InMemoryTerminalViewport) {
        let cols = viewport.columns
        let rows = viewport.rows
        ptyLog.notice("[grid] handleResize cols=\(cols) rows=\(rows) (was \(self.lastSize.cols)x\(self.lastSize.rows)) viewBounds=\(String(format: "%.0fx%.0f", self.view.bounds.width, self.view.bounds.height), privacy: .public) pty=\(self.ptyID, privacy: .public)")
        if cols == lastSize.cols, rows == lastSize.rows {
            ptyLog.notice("[grid] handleResize no-op (unchanged) pty=\(self.ptyID, privacy: .public)")
            return
        }
        lastSize = (cols, rows)
        pendingResize?.cancel()
        let client = self.client
        let ptyID = self.ptyID
        pendingResize = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.gridResizeDebounceMs))
            guard !Task.isCancelled else { return }
            ptyLog.notice("[grid] -> client.resize cols=\(cols) rows=\(rows) pty=\(ptyID, privacy: .public)")
            await client.resize(ptyID: ptyID, cols: cols, rows: rows)
            // The grid has settled to its final size AND the server now knows
            // it — open the first-open gate so the cold snapshot is generated
            // at (and fed into) this grid. See `firstOpenGate`.
            self?.firstOpenGate.signal()
            // Cache this settled grid so the next pty.create is born at the
            // device's real size — avoiding the 80×24→real column shrink that
            // re-wraps wide lines and desyncs the cursor. See `recordSettledGrid`.
            self?.terminals.recordSettledGrid(cols: cols, rows: rows)
        }
    }

    private func startPump() {
        guard pumpTask == nil else { return }

        let stream = client.outputs(for: ptyID)

        // Arm the first-open backstop: the normal open is the first settled
        // resize (handleResize → client.resize → firstOpenGate.signal), which
        // for a visible tab fires within ~1s. If the surface genuinely never
        // lays out, force the gate open after ~10s so the pump can't wedge.
        // (A short fixed timeout is wrong here — it could fire *before* the
        // surface lays out, opening the cold stream into a still-default-sized
        // terminal and feeding the grid-specific snapshot at the wrong grid,
        // which never recovers. The long backstop only covers "never settles".)
        let ptyID = self.ptyID
        firstOpenGate.signal(after: Self.gridSettleBackstop) {
            ptyLog.notice("[grid] first-open gate force-released after backstop (surface never settled) pty=\(ptyID, privacy: .public)")
        }

        pumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            // Hold the first open until the grid has settled (see `firstOpenGate`).
            // Returns instantly once open, so warm reactivate / tab re-switch is
            // instant.
            await self.firstOpenGate.wait()
            guard !Task.isCancelled else { return }
            await client.activatePtyStream(ptyID: ptyID, exclusive: self.exclusive)
            guard !Task.isCancelled else { return }
            for await data in stream {
                guard !Task.isCancelled else { return }
                session.receive(data)
                scheduleRenderNotify()
            }
            if !Task.isCancelled {
                pumpTask = nil
            }
        }
    }

    /// Trailing-debounced `.motifTerminalDidRender` post. The cursor may have
    /// moved as output landed; the active host view recomputes its keyboard
    /// lift off the new cursor position.
    private func scheduleRenderNotify() {
        pendingRenderNotify?.cancel()
        let ptyID = self.ptyID
        pendingRenderNotify = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.renderNotifyDebounceMs))
            guard let self, !self.disposed, !Task.isCancelled else { return }
            NotificationCenter.default.post(
                name: .motifTerminalDidRender,
                object: nil,
                userInfo: ["ptyID": ptyID]
            )
        }
    }

    private func stopPump() {
        pumpTask?.cancel()
        pumpTask = nil
        let client = self.client
        let ptyID = self.ptyID
        Task { await client.deactivatePtyStream(ptyID: ptyID) }
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        streaming = false
        stopPump()
        pendingResize?.cancel()
        pendingRenderNotify?.cancel()
        view.windowAttachmentHandler = nil
        view.delegate = nil
        view.removeFromSuperview()
        view.controller = nil
        terminals.unregister(ptyID: ptyID)
    }

    deinit {
        MainActor.assumeIsolated {
            dispose()
        }
    }
}

extension PtyTerminalRuntime: TerminalSurfaceFocusDelegate {
    /// Ghostty surface gained/lost keyboard focus. On gaining focus, claim PTY
    /// primary for this client (server `mark_primary` → resize the shared
    /// master to this device's grid) by re-activating this PTY's view — the
    /// same path a tab tap takes. Losing focus is a no-op: whichever client
    /// focuses next reclaims primary then.
    func terminalDidChangeFocus(_ focused: Bool) {
        guard focused, !disposed else { return }
        let client = self.client
        let ptyID = self.ptyID
        Task { @MainActor in
            if let vid = client.viewID(forPty: ptyID) {
                await client.activateView(viewID: vid)
            } else {
                client.reclaimPrimary()
            }
        }
    }
}
