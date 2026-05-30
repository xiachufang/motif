import Foundation
import Observation
import OSLog

/// Discriminator for QuickCommand behavior. `.bytes` (the default) writes
/// the fixed `payload` to the PTY. `.paste` reads `UIPasteboard.general.string`
/// at tap time — payload is unused but kept as `Data()` so persistence stays
/// uniform.
enum QuickCommandKind: String, Codable, Sendable {
    case bytes
    case paste
    /// Sticky Ctrl / Alt / Shift. Carry no payload — tapping toggles
    /// libghostty's per-view sticky-modifier state so the *next* key press
    /// carries the modifier. Kept in the command list (rather than hardcoded)
    /// so they can be reordered / removed / re-added like any other button.
    case ctrl
    case alt
    case shift
    /// Opens the directory picker; on confirm sends `cd '<path>'` to the
    /// active PTY. No payload — behavior lives in the BottomInputBar.
    case cd
}

/// Modifiers *baked into* a QuickCommand, applied on every tap regardless of
/// the sticky Ctrl/Alt/Shift state. Lets a single button send e.g. Ctrl+Alt+Del
/// in one tap. OR-ed with whatever sticky modifiers are armed at tap time.
///
/// Codable as `{ "rawValue": N }` (synthesized) — `decodeIfPresent` in
/// QuickCommand's decoder defaults it to `[]` so pre-modifier JSON still loads.
struct QuickCommandModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let ctrl  = QuickCommandModifiers(rawValue: 1 << 0)
    static let alt   = QuickCommandModifiers(rawValue: 1 << 1)
    static let shift = QuickCommandModifiers(rawValue: 1 << 2)

    /// Compact ⌃⌥⇧ glyph string in canonical order; "" when empty.
    var glyphs: String {
        var s = ""
        if contains(.ctrl)  { s += "⌃" }
        if contains(.alt)   { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        return s
    }

    /// Spelled-out names in canonical order, e.g. ["ctrl", "alt"]. Joined with
    /// " + " they read as "ctrl + alt"; empty when no modifiers are set.
    var names: [String] {
        var out: [String] = []
        if contains(.ctrl)  { out.append("ctrl") }
        if contains(.alt)   { out.append("alt") }
        if contains(.shift) { out.append("shift") }
        return out
    }
}

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
    var kind: QuickCommandKind
    /// Modifiers applied to `payload` on every tap (in addition to any sticky
    /// modifier armed at tap time). Empty for the vast majority of commands.
    var modifiers: QuickCommandModifiers

    init(
        id: UUID = UUID(),
        label: String,
        symbol: String? = nil,
        payload: Data,
        sendImmediately: Bool = true,
        kind: QuickCommandKind = .bytes,
        modifiers: QuickCommandModifiers = []
    ) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.payload = payload
        self.sendImmediately = sendImmediately
        self.kind = kind
        self.modifiers = modifiers
    }

    /// Copy with a fresh `id`. Used when seeding a per-program override
    /// from the global list so the two lists' rows stay independent.
    init(copyOf other: QuickCommand) {
        self.id = UUID()
        self.label = other.label
        self.symbol = other.symbol
        self.payload = other.payload
        self.sendImmediately = other.sendImmediately
        self.kind = other.kind
        self.modifiers = other.modifiers
    }

    // Swift's synthesized Codable does not honor `var` defaults for missing
    // keys — it throws `keyNotFound`. Hand-written decoder defaults `kind`
    // to `.bytes` so v1-persisted JSON (without the field) keeps loading.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        payload = try c.decode(Data.self, forKey: .payload)
        sendImmediately = try c.decode(Bool.self, forKey: .sendImmediately)
        kind = try c.decodeIfPresent(QuickCommandKind.self, forKey: .kind) ?? .bytes
        modifiers = try c.decodeIfPresent(QuickCommandModifiers.self, forKey: .modifiers) ?? []
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

    /// Paste-from-clipboard button. The payload at tap time is read from
    /// `UIPasteboard.general.string`, so the persisted `payload` stays empty.
    static func paste(label: String = "Paste", symbol: String? = "doc.on.clipboard") -> QuickCommand {
        QuickCommand(label: label, symbol: symbol, payload: Data(), sendImmediately: true, kind: .paste)
    }

    /// Sticky Ctrl modifier button. Empty payload — behavior lives in the
    /// BottomInputBar's modifier state machine.
    static func ctrlModifier() -> QuickCommand {
        QuickCommand(label: "Ctrl", symbol: "control", payload: Data(), kind: .ctrl)
    }

    /// Sticky Alt modifier button.
    static func altModifier() -> QuickCommand {
        QuickCommand(label: "Alt", symbol: "option", payload: Data(), kind: .alt)
    }

    /// Sticky Shift modifier button.
    static func shiftModifier() -> QuickCommand {
        QuickCommand(label: "Shift", symbol: "shift", payload: Data(), kind: .shift)
    }

    /// Directory-picker button. Empty payload — tapping opens the cd sheet.
    static func cd() -> QuickCommand {
        QuickCommand(label: "cd", symbol: "arrow.turn.down.right", payload: Data(), kind: .cd)
    }
}

/// Predefined "key-style" commands the editor can pick from. Each maps
/// to a fixed byte payload. Splitting them out as an enum lets the
/// editor offer a typed picker rather than free-form payload entry.
enum QuickCommandKey: String, CaseIterable, Codable, Sendable {
    case esc, tab, backTab, enter
    case up, down, left, right
    case home, end
    case pageUp, pageDown
    case backspace, forwardDelete, space
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case ctrlA, ctrlB, ctrlC, ctrlD, ctrlE, ctrlF, ctrlG, ctrlK, ctrlL
    case ctrlN, ctrlO, ctrlP, ctrlR, ctrlS, ctrlT, ctrlU, ctrlW, ctrlX, ctrlY, ctrlZ
    case ctrlQ, ctrlBackslash, ctrlSpace
    case pipe, slash, tilde, dash, underscore, backtick, singleQuote, doubleQuote

    var label: String {
        switch self {
        case .esc:         return "Esc"
        case .tab:         return "Tab"
        case .backTab:     return "⇤"
        case .enter:       return "↵"
        case .up:          return "↑"
        case .down:        return "↓"
        case .left:        return "←"
        case .right:       return "→"
        case .home:        return "Home"
        case .end:         return "End"
        case .pageUp:      return "PgUp"
        case .pageDown:    return "PgDn"
        case .backspace:   return "⌫"
        case .forwardDelete: return "⌦"
        case .space:       return "Space"
        case .f1:          return "F1"
        case .f2:          return "F2"
        case .f3:          return "F3"
        case .f4:          return "F4"
        case .f5:          return "F5"
        case .f6:          return "F6"
        case .f7:          return "F7"
        case .f8:          return "F8"
        case .f9:          return "F9"
        case .f10:         return "F10"
        case .f11:         return "F11"
        case .f12:         return "F12"
        case .ctrlA:       return "^A"
        case .ctrlB:       return "^B"
        case .ctrlC:       return "^C"
        case .ctrlD:       return "^D"
        case .ctrlE:       return "^E"
        case .ctrlF:       return "^F"
        case .ctrlG:       return "^G"
        case .ctrlK:       return "^K"
        case .ctrlL:       return "^L"
        case .ctrlN:       return "^N"
        case .ctrlO:       return "^O"
        case .ctrlP:       return "^P"
        case .ctrlR:       return "^R"
        case .ctrlS:       return "^S"
        case .ctrlT:       return "^T"
        case .ctrlU:       return "^U"
        case .ctrlW:       return "^W"
        case .ctrlX:       return "^X"
        case .ctrlY:       return "^Y"
        case .ctrlZ:       return "^Z"
        case .ctrlQ:       return "^Q"
        case .ctrlBackslash: return "^\\"
        case .ctrlSpace:   return "^Spc"
        case .pipe:        return "|"
        case .slash:       return "/"
        case .tilde:       return "~"
        case .dash:        return "-"
        case .underscore:  return "_"
        case .backtick:    return "`"
        case .singleQuote: return "'"
        case .doubleQuote: return "\""
        }
    }

    var symbol: String? {
        switch self {
        case .up:           return "arrow.up"
        case .down:         return "arrow.down"
        case .left:         return "arrow.left"
        case .right:        return "arrow.right"
        case .tab:          return "arrow.right.to.line"
        case .backTab:      return "arrow.left.to.line"
        case .backspace:    return "delete.left"
        case .forwardDelete: return "delete.right"
        default:            return nil
        }
    }

    var bytes: [UInt8] {
        switch self {
        case .esc:         return [0x1B]
        case .tab:         return [0x09]
        case .backTab:     return [0x1B, 0x5B, 0x5A]              // ESC [ Z (back-tab)
        case .enter:       return [0x0D]
        case .up:          return [0x1B, 0x5B, 0x41]
        case .down:        return [0x1B, 0x5B, 0x42]
        case .right:       return [0x1B, 0x5B, 0x43]
        case .left:        return [0x1B, 0x5B, 0x44]
        case .home:        return [0x1B, 0x5B, 0x48]
        case .end:         return [0x1B, 0x5B, 0x46]
        case .pageUp:      return [0x1B, 0x5B, 0x35, 0x7E]
        case .pageDown:    return [0x1B, 0x5B, 0x36, 0x7E]
        case .backspace:   return [0x7F]                          // DEL — what xterm/ghostty send for Backspace
        case .forwardDelete: return [0x1B, 0x5B, 0x33, 0x7E]      // ESC [ 3 ~
        case .space:       return [0x20]
        case .f1:          return [0x1B, 0x4F, 0x50]              // ESC O P
        case .f2:          return [0x1B, 0x4F, 0x51]
        case .f3:          return [0x1B, 0x4F, 0x52]
        case .f4:          return [0x1B, 0x4F, 0x53]
        case .f5:          return [0x1B, 0x5B, 0x31, 0x35, 0x7E]  // ESC [ 15 ~
        case .f6:          return [0x1B, 0x5B, 0x31, 0x37, 0x7E]
        case .f7:          return [0x1B, 0x5B, 0x31, 0x38, 0x7E]
        case .f8:          return [0x1B, 0x5B, 0x31, 0x39, 0x7E]
        case .f9:          return [0x1B, 0x5B, 0x32, 0x30, 0x7E]
        case .f10:         return [0x1B, 0x5B, 0x32, 0x31, 0x7E]
        case .f11:         return [0x1B, 0x5B, 0x32, 0x33, 0x7E]
        case .f12:         return [0x1B, 0x5B, 0x32, 0x34, 0x7E]
        case .ctrlA:       return [0x01]
        case .ctrlB:       return [0x02]
        case .ctrlC:       return [0x03]
        case .ctrlD:       return [0x04]
        case .ctrlE:       return [0x05]
        case .ctrlF:       return [0x06]
        case .ctrlG:       return [0x07]
        case .ctrlK:       return [0x0B]
        case .ctrlL:       return [0x0C]
        case .ctrlN:       return [0x0E]
        case .ctrlO:       return [0x0F]
        case .ctrlP:       return [0x10]
        case .ctrlR:       return [0x12]
        case .ctrlS:       return [0x13]
        case .ctrlT:       return [0x14]
        case .ctrlU:       return [0x15]
        case .ctrlW:       return [0x17]
        case .ctrlX:       return [0x18]
        case .ctrlY:       return [0x19]
        case .ctrlZ:       return [0x1A]
        case .ctrlQ:       return [0x11]
        case .ctrlBackslash: return [0x1C]                        // ^\ (SIGQUIT)
        case .ctrlSpace:   return [0x00]                          // NUL (^Space)
        case .pipe:        return [0x7C]
        case .slash:       return [0x2F]
        case .tilde:       return [0x7E]
        case .dash:        return [0x2D]
        case .underscore:  return [0x5F]
        case .backtick:    return [0x60]
        case .singleQuote: return [0x27]
        case .doubleQuote: return [0x22]
        }
    }

    func makeCommand() -> QuickCommand {
        QuickCommand(label: label, symbol: symbol, payload: Data(bytes), sendImmediately: true)
    }
}

/// One named quick-command set: a free display `name`, a list of program
/// names it `matches` (compared against `programKey(running)`), and its own
/// ordered command list. Display name and matching are decoupled — renaming
/// a set never changes what it matches, and a set can match many programs.
struct QuickCommandSet: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var matches: [String]
    var commands: [QuickCommand]

    init(id: UUID = UUID(), name: String, matches: [String] = [], commands: [QuickCommand] = []) {
        self.id = id
        self.name = name
        self.matches = matches
        self.commands = commands
    }
}

/// Which quick-command list a mutation / lookup targets: the shared global
/// list, or a specific named set (by id).
enum QuickCommandScope: Identifiable, Hashable, Sendable {
    case global
    case set(UUID)

    var id: String {
        switch self {
        case .global:        return "global"
        case .set(let uuid): return "set:\(uuid.uuidString)"
        }
    }
}

/// Persisted, ordered list of QuickCommands. Mirrors the
/// `MotifServerStore` shape but stores in UserDefaults — these are not
/// secrets and persisting alongside other prefs keeps things simple.
///
/// Beyond the single global list, the store holds optional per-program
/// override lists keyed by program name. The bottom bar resolves which
/// list to show from whatever command is currently running in the active
/// PTY (see `resolved(forRunning:)`).
@Observable
@MainActor
final class QuickCommandStore {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "QuickCommandStore")
    private static let listKey = "motif.quickCommands.v1"
    private static let setsKey = "motif.quickCommands.sets.v1"

    private(set) var commands: [QuickCommand] = []
    /// Named command sets, in match-precedence order (first match wins).
    private(set) var sets: [QuickCommandSet] = []

    init() {
        load()
        // No versioned migrations: if there's nothing persisted, or the
        // stored data can't be decoded (e.g. the schema changed), fall back
        // to the built-in defaults rather than trying to patch old shapes.
        if commands.isEmpty {
            commands = Self.seedDefaults()
            persist()
        }
    }

    // MARK: - Resolution

    /// Derive the override key (program name) from a raw running-command
    /// string: first whitespace-delimited token, then its path basename.
    /// `"claude --resume"` → `"claude"`, `"/usr/bin/vim f"` → `"vim"`.
    /// Empty / nil → nil (caller falls back to global).
    static func programKey(_ running: String?) -> String? {
        guard let running else { return nil }
        let trimmed = running.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let token: Substring
        if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            token = trimmed[..<space]
        } else {
            token = trimmed[...]
        }
        let noTrailingSlash = token.hasSuffix("/") ? token.dropLast() : token
        let leaf: Substring
        if let slash = noTrailingSlash.lastIndex(of: "/") {
            leaf = noTrailingSlash[noTrailingSlash.index(after: slash)...]
        } else {
            leaf = noTrailingSlash
        }
        return leaf.isEmpty ? nil : String(leaf)
    }

    /// First set (in array order) whose `matches` contains the running
    /// program's key, if any. Array order is match precedence.
    private func matchingSet(forRunning running: String?) -> QuickCommandSet? {
        guard let key = Self.programKey(running) else { return nil }
        return sets.first { $0.matches.contains(key) }
    }

    /// The effective list to render for whatever is currently running:
    /// the first matching set if one exists, else the global list.
    func resolved(forRunning running: String?) -> [QuickCommand] {
        matchingSet(forRunning: running)?.commands ?? commands
    }

    /// Which scope the bottom-bar pencil should edit for the running command.
    func effectiveScope(forRunning running: String?) -> QuickCommandScope {
        if let s = matchingSet(forRunning: running) { return .set(s.id) }
        return .global
    }

    // MARK: - Scope-aware access

    private func setIndex(_ id: UUID) -> Int? { sets.firstIndex { $0.id == id } }

    func list(_ scope: QuickCommandScope) -> [QuickCommand] {
        switch scope {
        case .global:      return commands
        case .set(let id): return setIndex(id).map { sets[$0].commands } ?? []
        }
    }

    func add(_ cmd: QuickCommand, to scope: QuickCommandScope) {
        mutate(scope) { $0.append(cmd) }
    }

    func update(_ cmd: QuickCommand, in scope: QuickCommandScope) {
        mutate(scope) {
            if let i = $0.firstIndex(where: { $0.id == cmd.id }) { $0[i] = cmd }
        }
    }

    func remove(id: UUID, from scope: QuickCommandScope) {
        mutate(scope) { $0.removeAll { $0.id == id } }
    }

    func remove(at offsets: IndexSet, from scope: QuickCommandScope) {
        mutate(scope) { $0.remove(atOffsets: offsets) }
    }

    func move(from source: IndexSet, to destination: Int, in scope: QuickCommandScope) {
        mutate(scope) { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// Create a new set seeded from a copy of the global list, so the user
    /// tweaks rather than rebuilds. Returns the new set's id so the caller
    /// can navigate straight to its editor.
    @discardableResult
    func createSet(name: String, matches: [String] = []) -> UUID {
        let new = QuickCommandSet(
            name: name,
            matches: matches,
            commands: commands.map { QuickCommand(copyOf: $0) }
        )
        sets.append(new)
        persist()
        return new.id
    }

    /// Delete a set; programs it matched revert to the global list.
    func removeSet(_ id: UUID) {
        sets.removeAll { $0.id == id }
        persist()
    }

    /// Rename a set's display name. Does not touch its matches.
    func renameSet(_ id: UUID, name: String) {
        guard let i = setIndex(id) else { return }
        sets[i].name = name
        persist()
    }

    /// Replace the program names a set matches against.
    func updateMatches(_ id: UUID, _ matches: [String]) {
        guard let i = setIndex(id) else { return }
        sets[i].matches = matches
        persist()
    }

    func resetToDefaults() {
        commands = Self.seedDefaults()
        persist()
    }

    /// Apply an in-place edit to the list backing `scope`, then persist.
    private func mutate(_ scope: QuickCommandScope, _ edit: (inout [QuickCommand]) -> Void) {
        switch scope {
        case .global:
            edit(&commands)
        case .set(let id):
            guard let i = setIndex(id) else { return }
            edit(&sets[i].commands)
        }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey) {
            do {
                commands = try JSONDecoder().decode([QuickCommand].self, from: data)
            } catch {
                // Unreadable (schema drift / corruption) → leave empty so the
                // caller restores defaults.
                log.error("decode QuickCommands: \(String(describing: error), privacy: .public)")
                commands = []
            }
        }
        if let data = UserDefaults.standard.data(forKey: Self.setsKey) {
            do {
                sets = try JSONDecoder().decode([QuickCommandSet].self, from: data)
            } catch {
                log.error("decode QuickCommand sets: \(String(describing: error), privacy: .public)")
                sets = []
            }
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(commands)
            UserDefaults.standard.set(data, forKey: Self.listKey)
        } catch {
            log.error("encode QuickCommands: \(String(describing: error), privacy: .public)")
        }
        do {
            let data = try JSONEncoder().encode(sets)
            UserDefaults.standard.set(data, forKey: Self.setsKey)
        } catch {
            log.error("encode QuickCommand sets: \(String(describing: error), privacy: .public)")
        }
    }

    /// Seed list installed on first launch — the user can edit / remove
    /// any of these. Ordered so the highest-value keys sit leftmost — the
    /// first ~6 are visible without horizontal scrolling on a phone, so they
    /// front-load what a terminal user reaches for most: Ctrl, Tab, Esc, and
    /// the arrows. Lower-frequency modifiers (Alt / Shift) and shell symbols
    /// follow; rarely-tapped symbols (_, `, ', ") are omitted from the seed
    /// but remain one tap away in the add sheet.
    private static func seedDefaults() -> [QuickCommand] {
        var out: [QuickCommand] = []
        // Prime real estate: the no-scroll set.
        out.append(.ctrlModifier())
        out.append(QuickCommandKey.tab.makeCommand())
        out.append(QuickCommandKey.esc.makeCommand())
        out.append(QuickCommandKey.up.makeCommand())
        out.append(QuickCommandKey.down.makeCommand())
        out.append(QuickCommandKey.left.makeCommand())
        out.append(QuickCommandKey.right.makeCommand())
        out.append(QuickCommandKey.ctrlC.makeCommand())
        // High-value actions, promoted up front so they don't need scrolling.
        out.append(.cd())
        out.append(.text(label: "ls", "ls\n"))
        out.append(.paste())
        // Editing / process control.
        out.append(QuickCommandKey.backspace.makeCommand())
        out.append(QuickCommandKey.ctrlD.makeCommand())
        // Secondary modifiers — available but out of the prime slots.
        out.append(.altModifier())
        out.append(.shiftModifier())
        // Shell symbols that are awkward to reach on the soft keyboard.
        out.append(QuickCommandKey.pipe.makeCommand())
        out.append(QuickCommandKey.slash.makeCommand())
        out.append(QuickCommandKey.dash.makeCommand())
        out.append(QuickCommandKey.tilde.makeCommand())
        out.append(.text(label: "cd ..", "cd ..\n"))
        return out
    }
}
