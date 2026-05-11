import SwiftUI
import UIKit
import SwiftTerm
import OSLog

private let ptyLog = Logger(subsystem: "io.allsunday.motif", category: "PtyView")

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

    func makeUIView(context: Context) -> TerminalView {
        let term = TerminalView()
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

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // No-op: dimensions and feed are fully driven by the coordinator
        // and SwiftTerm's own resize callback.
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let client: MotifClient
        let ptyID: String
        weak var terminal: TerminalView?
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

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // SwiftTerm hands us the raw bytes typed on the keyboard
            // (already encoded, including special key sequences). Forward
            // verbatim to the PTY.
            let bytes = Data(data)
            Task { [client, ptyID] in await client.write(ptyID: ptyID, data: bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let cols = UInt16(clamping: newCols)
            let rows = UInt16(clamping: newRows)
            if cols == lastSize.cols && rows == lastSize.rows { return }
            lastSize = (cols, rows)
            Task { [client, ptyID] in await client.resize(ptyID: ptyID, cols: cols, rows: rows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // not surfaced in MVP UI
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // not surfaced in MVP UI
        }

        func scrolled(source: TerminalView, position: Double) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: TerminalView) {
            // Could trigger a haptic; skipped for now.
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
