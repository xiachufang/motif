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
    let servers: MotifServerStore
    let motif: MotifClient = MotifClient()

    /// Show the Settings sheet on the WebView.
    var isShowingSettings: Bool = false

    /// Bumped each time the active motifd target changes, so the WebView
    /// can re-attach to a fresh upstream.
    private(set) var webViewReloadKey: Int = 0

    private var server: LocalHTTPServer?

    init() {
        let ts = TailscaleManager()
        let store = MotifServerStore()
        self.tailscale = ts
        self.servers = store
        // The proxy reads the active server lazily on each request — that
        // way switching servers in Settings takes effect immediately on the
        // next /ws or /blob request without restarting anything. The
        // closure hops to MainActor (MotifServerStore is isolated there)
        // before reading.
        self.proxy = TailscaleProxy(manager: ts) { [weak store] in
            await store?.activeServer
        }
    }

    private let proxy: TailscaleProxy

    /// Called by SettingsView after switching the active server, so the
    /// WebView reloads + drops any in-flight WS to the previous target.
    func bumpWebViewReload() {
        webViewReloadKey &+= 1
    }

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
