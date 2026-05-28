import Foundation
import Observation
import OSLog
import UIKit
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
    let terminalSettings: TerminalSettingsStore = TerminalSettingsStore()

    /// Drives the Connection sheet (Tailscale + Servers). Tapped via the
    /// server-name button on the top bar of NativeRoot, or implicitly
    /// from the Welcome screen.
    var isShowingConnection: Bool = false

    /// Drives the About sheet (bundle id + version).
    var isShowingAbout: Bool = false

    /// Bumped to force NativeRoot to rebuild + re-task the connection when
    /// something other than the active server changes (e.g. Tailscale flips
    /// from .stopped to .running and the previous connection bailed early).
    private(set) var nativeReloadKey: Int = 0

    init() {
        self.tailscale = TailscaleManager()
        self.servers = MotifServerStore()
        self.commands = QuickCommandStore()
        // Seed the terminal palette from the persisted theme so the very first
        // session.attach already carries the right OSC 10/11 colours, before
        // any SessionView mounts. SessionView re-pushes on theme changes.
        let systemDark = UITraitCollection.current.userInterfaceStyle == .dark
        terminals.applyTerminalSettings(
            fontSize: terminalSettings.fontSize,
            theme: terminalSettings.theme,
            systemDark: systemDark
        )
        motif.setTerminalPalette(
            fg: terminals.oscTermFg,
            bg: terminals.oscTermBg,
            theme: terminals.ptyColorScheme == .dark ? "dark" : "light"
        )
    }

    /// Called by ConnectionView after switching the active server, so
    /// NativeRoot drops any in-flight WS to the previous target.
    func bumpNativeReload() {
        nativeReloadKey &+= 1
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
    private var runtimes: [String: PtyTerminalRuntime] = [:]

    private final class WeakBox {
        weak var view: UITerminalView?
        init(_ v: UITerminalView) { self.view = v }
    }

    func register(_ view: UITerminalView, ptyID: String) {
        byPty[ptyID] = WeakBox(view)
        stickyVersion &+= 1
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
        stickyVersion &+= 1
    }

    func view(for ptyID: String?) -> UITerminalView? {
        guard let ptyID else { return nil }
        return byPty[ptyID]?.view
    }

    func runtime(client: MotifClient, ptyID: String) -> PtyTerminalRuntime {
        if let runtime = runtimes[ptyID] {
            return runtime
        }
        let runtime = PtyTerminalRuntime(client: client, ptyID: ptyID, terminals: self)
        runtimes[ptyID] = runtime
        return runtime
    }

    // MARK: - Terminal appearance

    /// Current global terminal appearance, applied to each runtime's Ghostty
    /// controller. New runtimes read these in `configureIfNeeded`; changes are
    /// pushed to live runtimes by `applyTerminalSettings`.
    private(set) var ptyFontSize: Float = Float(TerminalSettingsStore.defaultFontSize)
    private(set) var ptyColorScheme: TerminalColorScheme = .dark
    /// OSC 10/11 rgb strings (e.g. `"d0d0/d0d0/d0d0"`) for the current scheme,
    /// matching libghostty's default theme (afterglow dark / alabaster light).
    /// Read by callers that report the palette to motifd so PTY programs see
    /// the colours this surface actually renders. Kept in sync by
    /// `applyTerminalSettings`.
    private(set) var oscTermFg: String = ""
    private(set) var oscTermBg: String = ""

    /// Collapse the user's theme preference into a concrete light/dark scheme,
    /// resolving `.system` against the supplied OS appearance.
    static func resolveScheme(_ theme: TerminalThemeSetting, systemDark: Bool) -> TerminalColorScheme {
        switch theme {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return systemDark ? .dark : .light
        }
    }

    /// libghostty's default-theme background/foreground per scheme, encoded as
    /// the rgb portion of an OSC 10/11 reply (8-bit channels widened to 16).
    /// afterglow: bg #212121 / fg #D0D0D0; alabaster: bg #F7F7F7 / fg #000000.
    static func oscPalette(for scheme: TerminalColorScheme) -> (fg: String, bg: String) {
        switch scheme {
        case .dark:  return (fg: "d0d0/d0d0/d0d0", bg: "2121/2121/2121")
        case .light: return (fg: "0000/0000/0000", bg: "f7f7/f7f7/f7f7")
        }
    }

    /// Resolve the user's settings (font size + theme, with `systemDark`
    /// supplying the OS appearance for `.system`) and apply live to every
    /// open terminal surface.
    func applyTerminalSettings(fontSize: Double, theme: TerminalThemeSetting, systemDark: Bool) {
        let scheme = Self.resolveScheme(theme, systemDark: systemDark)
        let palette = Self.oscPalette(for: scheme)
        ptyFontSize = Float(fontSize)
        ptyColorScheme = scheme
        oscTermFg = palette.fg
        oscTermBg = palette.bg
        for (_, runtime) in runtimes {
            runtime.applyTerminalSettings()
        }
    }

    func syncRuntimes(client: MotifClient, livePtyIDs: Set<String>, activePtyID: String?) {
        pruneRuntimes(keeping: livePtyIDs)
        for (ptyID, runtime) in runtimes {
            runtime.setStreaming(ptyID == activePtyID)
        }
        if let activePtyID, livePtyIDs.contains(activePtyID) {
            runtime(client: client, ptyID: activePtyID).setStreaming(true)
        }
    }

    /// After a reconnect, re-open the active PTY's substream on the new
    /// connection so its live output resumes. Only the streaming (active)
    /// runtime needs this; inactive tabs catch up when next selected.
    func reactivate(activePtyID: String?) {
        guard let activePtyID, let runtime = runtimes[activePtyID] else { return }
        runtime.reactivate()
    }

    func pruneRuntimes(keeping livePtyIDs: Set<String>) {
        for ptyID in Array(runtimes.keys) where !livePtyIDs.contains(ptyID) {
            runtimes[ptyID]?.dispose()
            runtimes.removeValue(forKey: ptyID)
        }
    }
}
