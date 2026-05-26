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
        Coordinator(client: client, ptyID: ptyID, terminals: terminals)
    }

    func makeUIView(context: Context) -> MotifTerminalView {
        let view = MotifTerminalView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MotifTerminalView, context: Context) {
        // Configuration is set once in attach(to:); grid metrics flow
        // through the in-memory session's resize callback, output bytes
        // through the coordinator pump. Focus is Ghostty/UIKit default behavior.
    }

    @MainActor
    final class Coordinator: NSObject {
        let client: MotifClient
        let ptyID: String
        let terminals: TerminalRegistry
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

        init(
            client: MotifClient,
            ptyID: String,
            terminals: TerminalRegistry
        ) {
            self.client = client
            self.ptyID = ptyID
            self.terminals = terminals
            super.init()
            #if DEBUG
            _ = ghosttyDebugLogOnce
            #endif
        }

        func attach(to view: MotifTerminalView) {
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

            // Expose this view to BottomInputBar's Ctrl/Alt buttons so
            // they can drive libghostty's sticky-modifier state machine.
            // Registration installs a change handler that re-renders any
            // host UI mirroring the sticky state.
            terminals.register(view, ptyID: ptyID)

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
            let registry = terminals
            let id = ptyID
            Task { @MainActor in
                registry.unregister(ptyID: id)
            }
        }
    }
}
