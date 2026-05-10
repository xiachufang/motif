import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    enum ServerState: Equatable {
        case starting
        case running(port: UInt16)
        case failed(message: String)
    }

    private(set) var serverState: ServerState = .starting
    let tailscale: TailscaleManager

    /// Persisted via UserDefaults; user types this in Settings. Format
    /// "host:port" (e.g. "dev.tail-xxxx.ts.net:8765").
    var motifdAddress: String {
        get { UserDefaults.standard.string(forKey: "motifdAddress") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "motifdAddress") }
    }

    /// Show the Settings sheet on the WebView.
    var isShowingSettings: Bool = false

    private var server: LocalHTTPServer?

    init() {
        self.tailscale = TailscaleManager()
    }

    func startServerIfNeeded() async {
        if case .running = serverState { return }
        if server != nil { return }

        let s = LocalHTTPServer()
        server = s
        do {
            let port = try await s.start()
            serverState = .running(port: port)
        } catch {
            serverState = .failed(message: String(describing: error))
        }
    }
}
