import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class AppState {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "AppState")

    let tailscale: TailscaleManager
    let servers: MotifServerStore
    let motif: MotifClient = MotifClient()

    /// Drives the Connection sheet (Tailscale + Servers). Tapped via the
    /// server-name button on the top bar of NativeRoot, or implicitly
    /// from the Welcome screen.
    var isShowingConnection: Bool = false

    /// Drives the About sheet (bundle id + version).
    var isShowingAbout: Bool = false

    /// Bumped to force NativeRoot to rebuild + re-task the connection when
    /// something other than the active server changes (e.g. Tailscale flips
    /// from .stopped to .running and the previous connection bailed early).
    private(set) var webViewReloadKey: Int = 0

    init() {
        self.tailscale = TailscaleManager()
        self.servers = MotifServerStore()
    }

    /// Called by ConnectionView after switching the active server, so
    /// NativeRoot drops any in-flight WS to the previous target.
    func bumpWebViewReload() {
        webViewReloadKey &+= 1
    }
}
