import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class AppState {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "AppState")

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
        let ts = TailscaleManager()
        self.tailscale = ts
        // The proxy reads the motifd target lazily on each request, so the
        // user can change it in Settings without restarting the server.
        self.proxy = TailscaleProxy(manager: ts) {
            UserDefaults.standard.string(forKey: "motifdAddress") ?? ""
        }
    }

    private let proxy: TailscaleProxy

    func startServerIfNeeded() async {
        if case .running = serverState { return }
        if server != nil { return }

        let s = LocalHTTPServer(proxy: proxy)
        server = s
        do {
            let port = try await s.start()
            serverState = .running(port: port)
        } catch {
            log.error("local http server start: \(String(describing: error), privacy: .public)")
            serverState = .failed(message: String(describing: error))
        }
    }
}
