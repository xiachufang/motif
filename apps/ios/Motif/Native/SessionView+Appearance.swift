import SwiftUI

// Theme / appearance handling for `SessionView`. `applyAppearance` and
// `pushLocalThemeAsDriver` are driven from `SessionView.body`'s onChange
// handlers, so they are `internal`.
extension SessionView {
    /// The theme to RENDER: the session-wide theme when one is set (so every
    /// client looks identical and PTY output colours match), else this device's
    /// own preference.
    private func effectiveThemeSetting() -> TerminalThemeSetting {
        switch motif.sessionTheme {
        case "light": return .light
        case "dark":  return .dark
        default:      return appState.terminalSettings.theme
        }
    }

    /// Apply the effective appearance (font size + effective theme) to every
    /// open terminal surface. Pure render — does not touch the session theme.
    func applyAppearance() {
        appState.terminals.applyTerminalSettings(
            fontSize: appState.terminalSettings.fontSize,
            theme: effectiveThemeSetting(),
            systemDark: systemColorScheme == .dark
        )
    }

    /// Assert THIS device's own theme as the session-wide theme (+ OSC palette
    /// for the shell). Called when the user toggles theme or the system
    /// appearance flips — the focused/driving client's colours win. The server
    /// broadcasts `session.theme_changed`, which re-renders every client. A
    /// no-op when the local theme is unchanged.
    func pushLocalThemeAsDriver() {
        let scheme = TerminalRegistry.resolveScheme(
            appState.terminalSettings.theme, systemDark: systemColorScheme == .dark)
        let palette = TerminalRegistry.oscPalette(for: scheme)
        motif.setTerminalPalette(fg: palette.fg, bg: palette.bg, theme: scheme == .dark ? "dark" : "light")
    }
}
