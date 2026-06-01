import Foundation
import Observation
import OSLog

/// Terminal appearance preference. `.system` follows the iOS light/dark mode.
enum TerminalThemeSetting: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// Persisted, global terminal appearance: font size + light/dark theme.
/// Changes are applied live to every open Ghostty surface through
/// `TerminalRegistry.applyTerminalSettings(...)`.
@Observable
@MainActor
final class TerminalSettingsStore {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "TerminalSettings")
    private static let key = "motif.terminalSettings.v1"

    static let minFontSize: Double = 8
    static let maxFontSize: Double = 28
    /// Matches libghostty's calibrated iOS default so the out-of-box size is
    /// what the terminal showed before this setting existed.
    static let defaultFontSize: Double = 10

    var fontSize: Double { didSet { persist() } }
    var theme: TerminalThemeSetting { didSet { persist() } }
    /// Whether non-active terminal tabs keep their `/pty` stream open and keep
    /// advancing their (off-screen) surface in the background, vs. disconnecting
    /// and catching up on re-select. Default on — see `TerminalRegistry.syncRuntimes`.
    var keepInactiveTabsLive: Bool { didSet { persist() } }

    init() {
        let loaded = Self.load()
        fontSize = loaded?.fontSize ?? Self.defaultFontSize
        theme = loaded?.theme ?? .system
        keepInactiveTabsLive = loaded?.keepInactiveTabsLive ?? true
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var fontSize: Double
        var theme: TerminalThemeSetting
        // Optional so blobs persisted before this field still decode (they'd
        // otherwise fail the whole struct and reset font/theme too). Absent ⇒
        // default-on, applied in `init`.
        var keepInactiveTabsLive: Bool?
    }

    /// Missing or undecodable data → defaults (no migration).
    private static func load() -> Persisted? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }

    private func persist() {
        let p = Persisted(fontSize: fontSize, theme: theme, keepInactiveTabsLive: keepInactiveTabsLive)
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(p), forKey: Self.key)
        } catch {
            log.error("encode TerminalSettings: \(String(describing: error), privacy: .public)")
        }
    }
}
