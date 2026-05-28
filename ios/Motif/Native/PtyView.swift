import SwiftUI
import UIKit
import GhosttyTerminal
import OSLog

private let ptyLog = Logger(subsystem: "io.allsunday.motif", category: "PtyView")

#if DEBUG
/// DEBUG-only: route libghostty-spm's `TerminalDebugLog` into `FileLog` so
/// metric/lifecycle/action events land in `Documents/motif.log` alongside
/// the rest of our diagnostics. Categories deliberately exclude `.render`
/// and `.output` — they fire per-frame / per-byte and would drown the file.
/// Initialized lazily on the first Ghostty coordinator so non-Ghostty
/// sessions pay nothing.
private let ghosttyDebugLogOnce: Void = {
    TerminalDebugLog.sink = { message in
        FileLog.note("Ghostty", message)
    }
    TerminalDebugLog.enable([.lifecycle, .metrics, .actions])
}()
#endif

/// Motif-specific UITerminalView subclass. It suppresses ghostty's
/// bundled chip bar so Motif's BottomInputBar stays the single input
/// authority; touch and first-responder behavior otherwise stays with
/// Ghostty's default implementation.
final class MotifTerminalView: UITerminalView {
    override var inputAccessoryView: UIView? { nil }
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
    private var disposed = false
    private var lastSize: (cols: UInt16, rows: UInt16) = (0, 0)
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

    func setStreaming(_ active: Bool) {
        guard !disposed else { return }
        configureIfNeeded()
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
        Task { await client.activatePtyStream(ptyID: ptyID) }
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
        if cols == lastSize.cols, rows == lastSize.rows { return }
        lastSize = (cols, rows)
        pendingResize?.cancel()
        let client = self.client
        let ptyID = self.ptyID
        pendingResize = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            await client.resize(ptyID: ptyID, cols: cols, rows: rows)
        }
    }

    private func startPump() {
        guard pumpTask == nil else { return }

        let stream = client.outputs(for: ptyID)

        pumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await client.activatePtyStream(ptyID: ptyID)
            guard !Task.isCancelled else { return }
            for await data in stream {
                guard !Task.isCancelled else { return }
                session.receive(data)
            }
            if !Task.isCancelled {
                pumpTask = nil
            }
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
        view.windowAttachmentHandler = nil
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
