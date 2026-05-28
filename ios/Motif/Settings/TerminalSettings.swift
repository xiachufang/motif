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

    init() {
        let loaded = Self.load()
        fontSize = loaded?.fontSize ?? Self.defaultFontSize
        theme = loaded?.theme ?? .system
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var fontSize: Double
        var theme: TerminalThemeSetting
    }

    /// Missing or undecodable data → defaults (no migration).
    private static func load() -> Persisted? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }

    private func persist() {
        let p = Persisted(fontSize: fontSize, theme: theme)
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(p), forKey: Self.key)
        } catch {
            log.error("encode TerminalSettings: \(String(describing: error), privacy: .public)")
        }
    }
}
