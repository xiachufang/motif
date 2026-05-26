import Foundation
import Observation
import OSLog
import GhosttyTerminal

@Observable
@MainActor
final class AppState {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "AppState")

    let tailscale: TailscaleManager
    let servers: MotifServerStore
    let commands: QuickCommandStore
    let motif: MotifClient = MotifClient()
    let terminals: TerminalRegistry = TerminalRegistry()

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
        self.commands = QuickCommandStore()
    }

    /// Called by ConnectionView after switching the active server, so
    /// NativeRoot drops any in-flight WS to the previous target.
    func bumpWebViewReload() {
        webViewReloadKey &+= 1
    }
}

/// Maps live `UITerminalView`s by PTY id so BottomInputBar can drive
/// each PTY's built-in sticky-modifier state machine without owning
/// a duplicate one. Hosts that suppress Ghostty's bundled accessory
/// bar (we do) still need to forward Ctrl/Alt toggles to libghostty's
/// `stickyModifiers` — otherwise typed keyboard input on the terminal
/// won't see the modifier.
///
/// `stickyVersion` is bumped from each registered view's
/// `setStickyModifierChangeHandler`, so any SwiftUI view that reads it
/// in its body re-renders whenever Ghostty mutates sticky state
/// (toggle / consume / reset).
@Observable
@MainActor
final class TerminalRegistry {
    private(set) var stickyVersion: Int = 0
    private var byPty: [String: WeakBox] = [:]

    private final class WeakBox {
        weak var view: UITerminalView?
        init(_ v: UITerminalView) { self.view = v }
    }

    func register(_ view: UITerminalView, ptyID: String) {
        byPty[ptyID] = WeakBox(view)
        // Ghostty fires the change handler from its MainActor-isolated
        // sticky-state machine (toggle / consume / reset). Mutate the
        // observable counter synchronously via `assumeIsolated` so the
        // SwiftUI invalidation lands on the same run-loop turn — wrapping
        // in `Task { @MainActor }` defers the mutation past the next
        // render and the chip pill visibly lags behind the actual state.
        view.setStickyModifierChangeHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.stickyVersion &+= 1
            }
        }
    }

    func unregister(ptyID: String) {
        byPty[ptyID]?.view?.setStickyModifierChangeHandler(nil)
        byPty.removeValue(forKey: ptyID)
    }

    func view(for ptyID: String?) -> UITerminalView? {
        guard let ptyID else { return nil }
        return byPty[ptyID]?.view
    }
}
