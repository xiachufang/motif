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

/// libghostty-vt backed PTY surface. Wraps GhosttyTerminal's `UITerminalView`
/// + `InMemoryTerminalSession`: server PTY bytes -> `session.receive`,
/// terminal output bytes -> `client.write`, grid resize -> `client.resize`.
///
/// Focus model: SessionView holds two cooperating sources of truth —
/// `@FocusState<Bool>` for the composer TextField (SwiftUI-driven) and
/// `@State<Bool>` for the terminal (UIKit-driven through this view).
/// `isFocused == true` means we want UITerminalView to be first
/// responder; `updateUIView` reconciles UIKit FR to match. The tap GR
/// writes back through `setFocused(true)`, and SessionView's
/// `.onChange` watchers keep the two FR slots mutually exclusive — so
/// UIKit hands the keyboard off in place when the user flips between
/// terminal and TextField, no flicker.
///
/// motif-specific UITerminalView subclass. Overrides `inputAccessoryView`
/// to return `nil`, suppressing ghostty's bundled chip bar
/// (Esc/Ctrl/Alt/Cmd/Tab/arrows/Paste) so motif's BottomInputBar
/// (Quick Commands + TextField + Mic + Send) stays the single input
/// authority on the keyboard. Users who need raw Esc/Ctrl/arrow keys
/// add them as Quick Commands. Subclassing is possible because the
/// motif fork of libghostty-spm drops `final` from `UITerminalView`.
final class MotifTerminalView: UITerminalView {
    override var inputAccessoryView: UIView? { nil }
}

struct GhosttyPtyTerminal: UIViewRepresentable {
    let ptyID: String
    let initialCols: UInt16
    let initialRows: UInt16
    let client: MotifClient
    let isFocused: Bool
    let setFocused: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, ptyID: ptyID, setFocused: setFocused)
    }

    func makeUIView(context: Context) -> MotifTerminalView {
        let view = MotifTerminalView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MotifTerminalView, context: Context) {
        // Configuration is set once in attach(to:); grid metrics flow
        // through the in-memory session's resize callback, output bytes
        // through the coordinator pump. The one bit SwiftUI keeps live
        // is FR: reconcile UITerminalView's FR to the SwiftUI focus
        // state. Done async on main so we don't mutate FR mid-update
        // cycle.
        context.coordinator.setFocused = setFocused
        let want = isFocused
        if uiView.isFirstResponder != want {
            DispatchQueue.main.async {
                if want {
                    uiView.becomeFirstResponder()
                } else {
                    uiView.resignFirstResponder()
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let client: MotifClient
        let ptyID: String
        var setFocused: @MainActor (Bool) -> Void
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
            setFocused: @escaping @MainActor (Bool) -> Void
        ) {
            self.client = client
            self.ptyID = ptyID
            self.setFocused = setFocused
            super.init()
            #if DEBUG
            _ = ghosttyDebugLogOnce
            #endif
        }

        /// Tap GR installed on UITerminalView. Flips SwiftUI's
        /// `termFocused` state via `setFocused(true)`; `updateUIView`
        /// then drives the actual UIKit FR transition, which in turn
        /// makes UITerminalView's bundled `becomeFirstResponder`
        /// override set ghostty cursor focus and raise/own the software
        /// keyboard. The library's own `touchesBegan` already promotes
        /// FR when no soft keyboard is up — this GR covers the other
        /// case (BottomInputBar is FR + keyboard up), where the library
        /// deliberately skips `becomeFirstResponder()`.
        @objc func handleTapFocusTerminal(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            setFocused(true)
        }

        func attach(to view: MotifTerminalView) {
            let tap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleTapFocusTerminal(_:))
            )
            // `cancelsTouchesInView = false` so this GR coexists with
            // UITerminalView's pan/pinch recognizers and its own
            // touchesBegan/Ended bookkeeping — taps still pass through.
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
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

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
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
