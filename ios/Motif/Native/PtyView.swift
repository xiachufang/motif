import SwiftUI
import UIKit
import SwiftTerm
import GhosttyTerminal
import OSLog

private let ptyLog = Logger(subsystem: "io.allsunday.motif", category: "PtyView")

// SwiftTerm and GhosttyTerminal both export a `TerminalView` symbol
// (GhosttyTerminal as a typealias for `UITerminalView`). All SwiftTerm
// references below are spelled `SwiftTerm.TerminalView` so the bare name
// stays unambiguous; Ghostty references use `UITerminalView` directly.

/// Native PTY surface. Wraps SwiftTerm's UIKit `TerminalView` and pipes
/// keystrokes -> `pty.write`, `pty.output` events -> the terminal buffer.
/// Resize changes the terminal computes are forwarded as `pty.resize`.
struct PtyTerminal: UIViewRepresentable {
    let ptyID: String
    let initialCols: UInt16
    let initialRows: UInt16
    let client: MotifClient

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, ptyID: ptyID)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let term = SwiftTerm.TerminalView()
        term.terminalDelegate = context.coordinator
        term.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        term.nativeBackgroundColor = .black
        term.nativeForegroundColor = .white
        // SwiftTerm installs its own `TerminalAccessory` as the keyboard's
        // accessory view. We replace it with `nil` so our `BottomInputBar`
        // is the single authority for quick keys / mic / send. SwiftTerm
        // already defaults the UITextInputTraits (autocorrect / smart-*)
        // to `.no`, so no further config needed there.
        term.inputAccessoryView = nil
        // The terminal will reshape itself on first layout; SwiftTerm
        // recomputes cols/rows from the view bounds. We pass the requested
        // size via the dimension-change delegate as soon as it's known.
        context.coordinator.terminal = term
        // Spin up the output pump for this pty.
        context.coordinator.start()
        return term
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        // No-op: dimensions and feed are fully driven by the coordinator
        // and SwiftTerm's own resize callback.
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let client: MotifClient
        let ptyID: String
        weak var terminal: SwiftTerm.TerminalView?
        private var pumpTask: Task<Void, Never>?
        private var lastSize: (cols: UInt16, rows: UInt16) = (0, 0)

        init(client: MotifClient, ptyID: String) {
            self.client = client
            self.ptyID = ptyID
        }

        func start() {
            pumpTask = Task { [weak self] in
                guard let self else { return }
                let stream = self.client.outputs(for: self.ptyID)
                for await data in stream {
                    guard !Task.isCancelled else { return }
                    let bytes = [UInt8](data)
                    self.terminal?.feed(byteArray: bytes[...])
                }
            }
        }

        deinit {
            pumpTask?.cancel()
        }

        // MARK: TerminalViewDelegate

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            // SwiftTerm hands us the raw bytes typed on the keyboard
            // (already encoded, including special key sequences). Forward
            // verbatim to the PTY.
            let bytes = Data(data)
            Task { [client, ptyID] in await client.write(ptyID: ptyID, data: bytes) }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            let cols = UInt16(clamping: newCols)
            let rows = UInt16(clamping: newRows)
            if cols == lastSize.cols && rows == lastSize.rows { return }
            lastSize = (cols, rows)
            Task { [client, ptyID] in await client.resize(ptyID: ptyID, cols: cols, rows: rows) }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            // not surfaced in MVP UI
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
            // not surfaced in MVP UI
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: SwiftTerm.TerminalView) {
            // Could trigger a haptic; skipped for now.
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    }
}

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

/// libghostty-vt backed PTY surface. Wraps GhosttyTerminal's `UITerminalView`
/// + `InMemoryTerminalSession`: server PTY bytes -> `session.receive`,
/// terminal output bytes -> `client.write`, grid resize -> `client.resize`.
///
/// Selected via `AppState.terminalBackend == .ghostty`. Ghostty's bundled
/// `inputAccessoryView` (Esc/Ctrl/Alt/Cmd/Tab/arrows/Paste chips) is
/// disabled via `isInputAccessoryViewEnabled = false` so motif's
/// `BottomInputBar` (Quick Commands + TextField + Mic + Send) stays the
/// single input authority — matching the SwiftTerm path that pins
/// `term.inputAccessoryView = nil`. Users who need raw Esc/Ctrl/arrow
/// keys add them as Quick Commands. The flag itself is a motif-specific
/// addition to our fork of libghostty-spm
/// (gfreezy/libghostty-spm@motif/suppress-input-accessory).
struct GhosttyPtyTerminal: UIViewRepresentable {
    let ptyID: String
    let initialCols: UInt16
    let initialRows: UInt16
    let client: MotifClient

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, ptyID: ptyID)
    }

    func makeUIView(context: Context) -> UITerminalView {
        let view = UITerminalView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UITerminalView, context: Context) {
        // Configuration is set once in attach(to:); grid metrics flow
        // through the in-memory session's resize callback, output bytes
        // through the coordinator pump. Nothing for SwiftUI to push.
    }

    @MainActor
    final class Coordinator {
        let client: MotifClient
        let ptyID: String
        private let controller = TerminalController()
        private var session: InMemoryTerminalSession?
        private var pumpTask: Task<Void, Never>?
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

        init(client: MotifClient, ptyID: String) {
            self.client = client
            self.ptyID = ptyID
            #if DEBUG
            _ = ghosttyDebugLogOnce
            #endif
        }

        func attach(to view: UITerminalView) {
            view.isInputAccessoryViewEnabled = false
            let client = self.client
            let ptyID = self.ptyID
            let session = InMemoryTerminalSession(
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
            self.session = session

            view.controller = controller
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

            pumpTask = Task { @MainActor [weak self, weak session] in
                guard let self else { return }
                let stream = self.client.outputs(for: self.ptyID)
                for await data in stream {
                    guard !Task.isCancelled else { return }
                    session?.receive(data)
                }
            }
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

        deinit {
            pumpTask?.cancel()
            pendingResize?.cancel()
        }
    }
}
