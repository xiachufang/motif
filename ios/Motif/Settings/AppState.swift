import Foundation
import Observation
import OSLog

enum TerminalBackend: String, CaseIterable, Identifiable, Sendable {
    case swiftTerm
    case ghostty
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .swiftTerm: "SwiftTerm"
        case .ghostty: "Ghostty"
        }
    }
}

@Observable
@MainActor
final class AppState {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "AppState")

    let tailscale: TailscaleManager
    let servers: MotifServerStore
    let commands: QuickCommandStore
    let motif: MotifClient = MotifClient()

    /// Drives the Connection sheet (Tailscale + Servers). Tapped via the
    /// server-name button on the top bar of NativeRoot, or implicitly
    /// from the Welcome screen.
    var isShowingConnection: Bool = false

    /// Drives the About sheet (bundle id + version).
    var isShowingAbout: Bool = false

    /// Active terminal renderer. Persisted in UserDefaults — switching
    /// rebuilds the PTY view in place; scrollback is replayed from
    /// `MotifClient`'s per-PTY ring buffer.
    var terminalBackend: TerminalBackend {
        didSet {
            guard oldValue != terminalBackend else { return }
            UserDefaults.standard.set(terminalBackend.rawValue, forKey: Self.backendKey)
        }
    }
    private static let backendKey = "terminal_backend"

    /// Bumped to force NativeRoot to rebuild + re-task the connection when
    /// something other than the active server changes (e.g. Tailscale flips
    /// from .stopped to .running and the previous connection bailed early).
    private(set) var webViewReloadKey: Int = 0

    init() {
        self.tailscale = TailscaleManager()
        self.servers = MotifServerStore()
        self.commands = QuickCommandStore()
        if let raw = UserDefaults.standard.string(forKey: Self.backendKey),
           let backend = TerminalBackend(rawValue: raw) {
            self.terminalBackend = backend
        } else {
            self.terminalBackend = .swiftTerm
        }
    }

    /// Called by ConnectionView after switching the active server, so
    /// NativeRoot drops any in-flight WS to the previous target.
    func bumpWebViewReload() {
        webViewReloadKey &+= 1
    }
}
