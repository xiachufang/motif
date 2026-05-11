import Foundation
import Observation
import OSLog

/// One configurable button in the BottomInputBar's quick-command row.
///
/// `payload` is the raw byte sequence sent to the active PTY's stdin.
/// `sendImmediately == true` writes those bytes the moment the user taps;
/// `false` inserts the (UTF-8 decoded) text into the BottomInputBar's
/// TextField buffer, so the user can edit before submitting.
struct QuickCommand: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var label: String
    /// Optional SF Symbol name. When set, the row renders the symbol
    /// instead of the label text — `command` / `arrow.up` / etc.
    var symbol: String?
    /// Bytes written to the PTY (or inserted into the text buffer).
    /// Stored as raw Data so ANSI escape sequences (Esc = 0x1B,
    /// arrows = 0x1B 0x5B 0x41..0x44) round-trip cleanly through Codable.
    var payload: Data
    var sendImmediately: Bool

    init(
        id: UUID = UUID(),
        label: String,
        symbol: String? = nil,
        payload: Data,
        sendImmediately: Bool = true
    ) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.payload = payload
        self.sendImmediately = sendImmediately
    }
}

extension QuickCommand {
    /// Convenience for snippets typed as Swift strings (e.g. "ls").
    static func text(label: String, symbol: String? = nil, _ s: String, sendImmediately: Bool = true) -> QuickCommand {
        QuickCommand(label: label, symbol: symbol, payload: Data(s.utf8), sendImmediately: sendImmediately)
    }

    /// Convenience for raw byte sequences (control / escape codes).
    static func bytes(label: String, symbol: String? = nil, _ bytes: [UInt8], sendImmediately: Bool = true) -> QuickCommand {
        QuickCommand(label: label, symbol: symbol, payload: Data(bytes), sendImmediately: sendImmediately)
    }
}

/// Predefined "key-style" commands the editor can pick from. Each maps
/// to a fixed byte payload. Splitting them out as an enum lets the
/// editor offer a typed picker rather than free-form payload entry.
enum QuickCommandKey: String, CaseIterable, Codable, Sendable {
    case esc, tab, enter
    case up, down, left, right
    case home, end
    case pageUp, pageDown
    case ctrlA, ctrlB, ctrlC, ctrlD, ctrlE, ctrlF, ctrlG, ctrlK, ctrlL
    case ctrlN, ctrlP, ctrlR, ctrlT, ctrlU, ctrlW, ctrlY, ctrlZ

    var label: String {
        switch self {
        case .esc:       return "Esc"
        case .tab:       return "Tab"
        case .enter:     return "↵"
        case .up:        return "↑"
        case .down:      return "↓"
        case .left:      return "←"
        case .right:     return "→"
        case .home:      return "Home"
        case .end:       return "End"
        case .pageUp:    return "PgUp"
        case .pageDown:  return "PgDn"
        case .ctrlA:     return "^A"
        case .ctrlB:     return "^B"
        case .ctrlC:     return "^C"
        case .ctrlD:     return "^D"
        case .ctrlE:     return "^E"
        case .ctrlF:     return "^F"
        case .ctrlG:     return "^G"
        case .ctrlK:     return "^K"
        case .ctrlL:     return "^L"
        case .ctrlN:     return "^N"
        case .ctrlP:     return "^P"
        case .ctrlR:     return "^R"
        case .ctrlT:     return "^T"
        case .ctrlU:     return "^U"
        case .ctrlW:     return "^W"
        case .ctrlY:     return "^Y"
        case .ctrlZ:     return "^Z"
        }
    }

    var symbol: String? {
        switch self {
        case .up:    return "arrow.up"
        case .down:  return "arrow.down"
        case .left:  return "arrow.left"
        case .right: return "arrow.right"
        case .tab:   return "arrow.right.to.line"
        default:     return nil
        }
    }

    var bytes: [UInt8] {
        switch self {
        case .esc:      return [0x1B]
        case .tab:      return [0x09]
        case .enter:    return [0x0D]
        case .up:       return [0x1B, 0x5B, 0x41]
        case .down:     return [0x1B, 0x5B, 0x42]
        case .right:    return [0x1B, 0x5B, 0x43]
        case .left:     return [0x1B, 0x5B, 0x44]
        case .home:     return [0x1B, 0x5B, 0x48]
        case .end:      return [0x1B, 0x5B, 0x46]
        case .pageUp:   return [0x1B, 0x5B, 0x35, 0x7E]
        case .pageDown: return [0x1B, 0x5B, 0x36, 0x7E]
        case .ctrlA:    return [0x01]
        case .ctrlB:    return [0x02]
        case .ctrlC:    return [0x03]
        case .ctrlD:    return [0x04]
        case .ctrlE:    return [0x05]
        case .ctrlF:    return [0x06]
        case .ctrlG:    return [0x07]
        case .ctrlK:    return [0x0B]
        case .ctrlL:    return [0x0C]
        case .ctrlN:    return [0x0E]
        case .ctrlP:    return [0x10]
        case .ctrlR:    return [0x12]
        case .ctrlT:    return [0x14]
        case .ctrlU:    return [0x15]
        case .ctrlW:    return [0x17]
        case .ctrlY:    return [0x19]
        case .ctrlZ:    return [0x1A]
        }
    }

    func makeCommand() -> QuickCommand {
        QuickCommand(label: label, symbol: symbol, payload: Data(bytes), sendImmediately: true)
    }
}

/// Persisted, ordered list of QuickCommands. Mirrors the
/// `MotifServerStore` shape but stores in UserDefaults — these are not
/// secrets and persisting alongside other prefs keeps things simple.
@Observable
@MainActor
final class QuickCommandStore {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "QuickCommandStore")
    private static let listKey = "motif.quickCommands.v1"

    private(set) var commands: [QuickCommand] = []

    init() {
        load()
        if commands.isEmpty {
            commands = Self.seedDefaults()
            persist()
        }
    }

    func add(_ cmd: QuickCommand) {
        commands.append(cmd)
        persist()
    }

    func update(_ cmd: QuickCommand) {
        guard let i = commands.firstIndex(where: { $0.id == cmd.id }) else { return }
        commands[i] = cmd
        persist()
    }

    func remove(id: UUID) {
        commands.removeAll { $0.id == id }
        persist()
    }

    func remove(at offsets: IndexSet) {
        commands.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        commands.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func resetToDefaults() {
        commands = Self.seedDefaults()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.listKey) else { return }
        do {
            commands = try JSONDecoder().decode([QuickCommand].self, from: data)
        } catch {
            log.error("decode QuickCommands: \(String(describing: error), privacy: .public)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(commands)
            UserDefaults.standard.set(data, forKey: Self.listKey)
        } catch {
            log.error("encode QuickCommands: \(String(describing: error), privacy: .public)")
        }
    }

    /// Seed list installed on first launch — the user can edit / remove
    /// any of these. Order matches what most users tap most often:
    /// movement first (esc / tab / arrows), then process control
    /// (ctrl-c / ctrl-d), then a couple of staple shell snippets.
    private static func seedDefaults() -> [QuickCommand] {
        var out: [QuickCommand] = []
        out.append(QuickCommandKey.esc.makeCommand())
        out.append(QuickCommandKey.tab.makeCommand())
        out.append(QuickCommandKey.up.makeCommand())
        out.append(QuickCommandKey.down.makeCommand())
        out.append(QuickCommandKey.left.makeCommand())
        out.append(QuickCommandKey.right.makeCommand())
        out.append(QuickCommandKey.ctrlC.makeCommand())
        out.append(QuickCommandKey.ctrlD.makeCommand())
        out.append(.text(label: "cd ..", "cd ..\n"))
        out.append(.text(label: "ls",    "ls\n"))
        return out
    }
}
