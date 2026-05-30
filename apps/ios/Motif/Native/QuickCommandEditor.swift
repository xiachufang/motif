import SwiftUI

/// Sheet wrapper used by the BottomInputBar pencil button. Wraps the
/// reusable `QuickCommandListEditor` in its own NavigationStack + Done
/// button. The `scope` is whichever list is currently effective (global
/// or a per-program override) — see `effectiveScope(forRunning:)`.
struct QuickCommandEditor: View {
    let scope: QuickCommandScope
    /// Program running in the active PTY (e.g. "claude"), forwarded to the
    /// "all sets" manager as a one-tap "customize this" shortcut.
    var runningProgram: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuickCommandListEditor(scope: scope)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            QuickCommandSetsView(runningProgram: runningProgram)
                        } label: {
                            Image(systemName: "rectangle.stack")
                        }
                    }
                }
        }
    }
}

/// Navigation-agnostic editor for one quick-command list (`scope`). Reorder
/// via drag handles, swipe-to-delete, tap a row to edit it, or "+" to add a
/// new entry (special key from the predefined enum, or a free-form text
/// snippet). An overflow menu resets the global list / deletes a per-program
/// customization. All mutations go through `QuickCommandStore` which
/// re-persists immediately.
///
/// Embeds no NavigationStack of its own, so it works both pushed (from the
/// manage-all view) and inside a sheet wrapper (the pencil entry).
struct QuickCommandListEditor: View {
    let scope: QuickCommandScope
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false
    @State private var editing: QuickCommand?
    @State private var showingRename = false
    @State private var renameTarget = ""
    @State private var showingMatches = false

    private var items: [QuickCommand] { appState.commands.list(scope) }

    private var title: String {
        switch scope {
        case .global:      return "Global"
        case .set(let id): return appState.commands.sets.first { $0.id == id }?.name ?? "Set"
        }
    }

    var body: some View {
        List {
            ForEach(items) { cmd in
                if cmd.kind != .bytes {
                    // Paste / Ctrl / Alt / cd have no editable payload —
                    // paste reads the clipboard, modifiers toggle sticky
                    // state, cd opens the picker. Keep them visible /
                    // reorderable / deletable, just not tappable-to-edit.
                    row(cmd)
                } else {
                    Button {
                        editing = cmd
                    } label: {
                        row(cmd)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onMove { from, to in appState.commands.move(from: from, to: to, in: scope) }
            .onDelete { offsets in appState.commands.remove(at: offsets, from: scope) }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    switch scope {
                    case .global:
                        Button {
                            appState.commands.resetToDefaults()
                        } label: { Label("Reset to defaults", systemImage: "arrow.counterclockwise") }
                    case .set(let id):
                        Button {
                            renameTarget = appState.commands.sets.first { $0.id == id }?.name ?? ""
                            showingRename = true
                        } label: { Label("Rename…", systemImage: "pencil") }
                        Button {
                            showingMatches = true
                        } label: { Label("Edit matched programs…", systemImage: "text.badge.plus") }
                        Divider()
                        Button(role: .destructive) {
                            appState.commands.removeSet(id)
                            dismiss()
                        } label: { Label("Delete set", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingAdd = true
                    } label: { Label("Key or text snippet", systemImage: "keyboard") }
                    Button {
                        appState.commands.add(.paste(), to: scope)
                    } label: { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                        .disabled(items.contains { $0.kind == .paste })
                    Button {
                        appState.commands.add(.ctrlModifier(), to: scope)
                    } label: { Label("Ctrl modifier", systemImage: "control") }
                        .disabled(items.contains { $0.kind == .ctrl })
                    Button {
                        appState.commands.add(.altModifier(), to: scope)
                    } label: { Label("Alt modifier", systemImage: "option") }
                        .disabled(items.contains { $0.kind == .alt })
                    Button {
                        appState.commands.add(.shiftModifier(), to: scope)
                    } label: { Label("Shift modifier", systemImage: "shift") }
                        .disabled(items.contains { $0.kind == .shift })
                    Button {
                        appState.commands.add(.cd(), to: scope)
                    } label: { Label("Change directory", systemImage: "arrow.turn.down.right") }
                        .disabled(items.contains { $0.kind == .cd })
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCommandSheet { cmd in
                appState.commands.add(cmd, to: scope)
                showingAdd = false
            } onCancel: { showingAdd = false }
        }
        .sheet(item: $editing) { cmd in
            QuickCommandRowEditor(initial: cmd) { updated in
                appState.commands.update(updated, in: scope)
                editing = nil
            } onCancel: { editing = nil }
        }
        .alert("Rename set", isPresented: $showingRename) {
            TextField("Name", text: $renameTarget)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if case .set(let id) = scope {
                    let n = renameTarget.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { appState.commands.renameSet(id, name: n) }
                }
            }
        }
        .sheet(isPresented: $showingMatches) {
            if case .set(let id) = scope,
               let set = appState.commands.sets.first(where: { $0.id == id }) {
                MatchedProgramsEditor(initial: set.matches) { updated in
                    appState.commands.updateMatches(id, updated)
                    showingMatches = false
                } onCancel: { showingMatches = false }
            }
        }
    }

    @ViewBuilder
    private func row(_ cmd: QuickCommand) -> some View {
        HStack(spacing: 10) {
            if let symbol = cmd.symbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .frame(width: 20)
                    .foregroundStyle(.tint)
            } else {
                Text(cmd.label.isEmpty ? "·" : String(cmd.label.prefix(2)))
                    .font(MotifTheme.Typography.caption.bold().monospaced())
                    .frame(width: 20)
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(cmd.label)
                    .font(MotifTheme.Typography.body)
                Text(subtitle(cmd))
                    .font(MotifTheme.Typography.caption.monospaced())
                    .foregroundStyle(MotifTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            // The send/insert glyph only means something for byte payloads.
            if cmd.kind == .bytes {
                Image(systemName: cmd.sendImmediately ? "paperplane.fill" : "text.insert")
                    .foregroundStyle(MotifTheme.textSecondary)
                    .font(MotifTheme.Typography.caption)
            }
        }
    }

    /// Secondary line under the label. Byte commands show their payload;
    /// the special kinds describe their behavior instead of an empty payload.
    private func subtitle(_ cmd: QuickCommand) -> String {
        switch cmd.kind {
        case .paste:      return "clipboard"
        case .ctrl, .alt, .shift: return "sticky modifier"
        case .cd:         return "directory picker"
        case .bytes:
            let preview = payloadPreview(cmd.payload)
            let g = cmd.modifiers.glyphs
            return g.isEmpty ? preview : "\(g) \(preview)"
        }
    }

    /// Render `payload` for the editor preview. Printable ASCII passes
    /// through; control bytes are shown as `^X` / `\e` so the user can
    /// tell at a glance what an "Esc" or arrow row actually sends.
    private func payloadPreview(_ data: Data) -> String {
        if data.isEmpty { return "(empty)" }
        var out = ""
        for b in data {
            switch b {
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x1B: out += "\\e"
            case 0x20...0x7E: out.append(Character(UnicodeScalar(b)))
            case 0x01...0x1A:
                let letter = Character(UnicodeScalar(0x40 + UInt32(b))!)
                out += "^\(letter)"
            default:
                out += String(format: "\\x%02x", b)
            }
        }
        return out
    }
}

// MARK: - Special key picker

/// Unified "add a command" sheet. A segmented control flips between two
/// modes that used to be separate menu entries:
///   • Key — tap any special key, function key, or printable character to add
///     it immediately (one byte / escape sequence each).
///   • Snippet — free-form label + payload + modifiers, committed via "Add".
private struct AddCommandSheet: View {
    let onAdd: (QuickCommand) -> Void
    let onCancel: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case key = "Key", snippet = "Snippet"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .key

    // Snippet-mode fields.
    @State private var label = ""
    @State private var symbol = ""
    @State private var payloadText = ""
    @State private var sendImmediately = true
    @State private var modCtrl = false
    @State private var modAlt = false
    @State private var modShift = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Type", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
                .padding(.bottom, 4)

                switch mode {
                case .key:
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            modChip("Ctrl", isOn: $modCtrl)
                            modChip("Alt", isOn: $modAlt)
                            modChip("Shift", isOn: $modShift)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                        comboPreview
                        KeyCatalog(modifiers: selectedModifiers, onPick: onAdd)
                    }
                case .snippet:
                    Form {
                        SnippetFields(
                            label: $label, symbol: $symbol, payloadText: $payloadText,
                            sendImmediately: $sendImmediately,
                            modCtrl: $modCtrl, modAlt: $modAlt, modShift: $modShift
                        )
                    }
                }
            }
            .navigationTitle("Add command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onCancel() } }
                if mode == .snippet {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Add") { addSnippet() }
                            .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    /// Modifiers selected by the Ctrl/Alt/Shift toggles, shared by both modes.
    private var selectedModifiers: QuickCommandModifiers {
        var mods: QuickCommandModifiers = []
        if modCtrl  { mods.insert(.ctrl) }
        if modAlt   { mods.insert(.alt) }
        if modShift { mods.insert(.shift) }
        return mods
    }

    /// Compact toggle chip, sized to its label. Selected state is an accent
    /// fill so it reads clearly as "armed"; unselected is the subtle strip fill.
    @ViewBuilder
    private func modChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(MotifTheme.Typography.caption.monospaced())
                .padding(.horizontal, MotifTheme.Spacing.md)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isOn.wrappedValue ? MotifTheme.accent : MotifTheme.Fill.subtle)
                )
                .foregroundStyle(isOn.wrappedValue ? MotifTheme.textOnAccent : MotifTheme.textPrimary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Live "ctrl + alt + key" line showing exactly what tapping a key adds.
    /// Hidden when no modifier is armed (the key is added bare).
    @ViewBuilder
    private var comboPreview: some View {
        if !selectedModifiers.names.isEmpty {
            Text((selectedModifiers.names + ["key"]).joined(separator: " + "))
                .font(MotifTheme.Typography.caption.monospaced())
                .foregroundStyle(MotifTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        }
    }

    private func addSnippet() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onAdd(QuickCommand(
            label: trimmed,
            symbol: symbol.trimmingCharacters(in: .whitespaces).isEmpty ? nil : symbol,
            payload: qcEncode(payloadText),
            sendImmediately: sendImmediately,
            modifiers: selectedModifiers
        ))
    }
}

/// Exhaustive key catalog for the add sheet's "Key" mode: the curated
/// `QuickCommandKey` set (movement / function / control / editing) plus every
/// printable ASCII character as a one-tap button. Each tap builds a
/// send-immediately QuickCommand and hands it back via `onPick`.
private struct KeyCatalog: View {
    /// Baked into every command this catalog produces (from the add sheet's
    /// Ctrl/Alt/Shift toggles).
    let modifiers: QuickCommandModifiers
    let onPick: (QuickCommand) -> Void

    var body: some View {
        List {
            // Only keys that a modifier + character can't reproduce. Ctrl-letter
            // combos (^C, ^D, …) are intentionally absent — arm the Ctrl chip
            // above and tap the letter instead.
            Section("Movement") {
                keyRow(.esc); keyRow(.tab); keyRow(.backTab); keyRow(.enter)
                keyRow(.up); keyRow(.down); keyRow(.left); keyRow(.right)
                keyRow(.home); keyRow(.end); keyRow(.pageUp); keyRow(.pageDown)
            }
            Section("Editing") {
                keyRow(.backspace); keyRow(.forwardDelete)
            }
            Section("Function keys") {
                keyRow(.f1); keyRow(.f2); keyRow(.f3); keyRow(.f4)
                keyRow(.f5); keyRow(.f6); keyRow(.f7); keyRow(.f8)
                keyRow(.f9); keyRow(.f10); keyRow(.f11); keyRow(.f12)
            }
            Section("Digits") { charGrid("0123456789") }
            Section("Lowercase") { charGrid("abcdefghijklmnopqrstuvwxyz") }
            Section("Uppercase") { charGrid("ABCDEFGHIJKLMNOPQRSTUVWXYZ") }
            // Every remaining printable ASCII symbol (0x21–0x7E minus the
            // alphanumerics above). Space has its own `.space` key.
            Section("Symbols") { charGrid("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~") }
        }
    }

    @ViewBuilder
    private func keyRow(_ key: QuickCommandKey) -> some View {
        Button {
            var cmd = key.makeCommand()
            cmd.modifiers = modifiers
            onPick(cmd)
        } label: {
            HStack {
                if let s = key.symbol {
                    Image(systemName: s).frame(width: 22)
                } else {
                    Text(key.label).frame(width: 22, alignment: .leading)
                        .font(MotifTheme.Typography.caption.bold().monospaced())
                }
                // Spell the full combo so the row reads as the command it adds,
                // e.g. "ctrl + alt + Esc"; bare key label when no modifier.
                Text((modifiers.names + [key.label]).joined(separator: " + "))
                    .foregroundStyle(MotifTheme.textPrimary)
                Spacer()
            }
        }
    }

    /// A wrapping grid of single-character buttons. Each sends that one
    /// character verbatim (plus any selected modifiers) when tapped.
    @ViewBuilder
    private func charGrid(_ chars: String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 8)], spacing: 8) {
            ForEach(Array(chars), id: \.self) { c in
                Button {
                    onPick(QuickCommand(label: String(c), payload: Data(String(c).utf8), sendImmediately: true, modifiers: modifiers))
                } label: {
                    Text(String(c))
                        .font(MotifTheme.Typography.body.monospaced())
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shared label / symbol / modifiers / payload form sections, reused by both
/// the add sheet's Snippet mode and the per-row editor. Embed inside a `Form`.
private struct SnippetFields: View {
    @Binding var label: String
    @Binding var symbol: String
    @Binding var payloadText: String
    @Binding var sendImmediately: Bool
    @Binding var modCtrl: Bool
    @Binding var modAlt: Bool
    @Binding var modShift: Bool

    var body: some View {
        Group {
            Section("Display") {
                TextField("Label", text: $label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("SF Symbol (optional)", text: $symbol)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                Toggle("Ctrl", isOn: $modCtrl)
                Toggle("Alt / Option", isOn: $modAlt)
                Toggle("Shift", isOn: $modShift)
            } header: {
                Text("Modifiers")
            } footer: {
                Text("Applied to the payload on every tap, in addition to any sticky Ctrl/Alt/Shift armed at tap time. Ignored unless \"Send immediately\" is on.")
            }
            Section {
                TextEditor(text: $payloadText)
                    .font(MotifTheme.Typography.body.monospaced())
                    .frame(minHeight: 80)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Toggle("Send immediately", isOn: $sendImmediately)
            } header: {
                Text("Payload")
            } footer: {
                Text("Sent verbatim to the active PTY when this button is tapped. \\n / \\t / \\e are interpreted as newline / tab / escape.")
            }
        }
    }
}

// MARK: - Matched-programs editor

/// Edit the list of program names a set matches against. Entries are
/// normalized through `programKey` (so "/usr/bin/vim" stores as "vim"),
/// matching the space the resolver compares against. Commits only on Done.
private struct MatchedProgramsEditor: View {
    let initial: [String]
    let onSubmit: ([String]) -> Void
    let onCancel: () -> Void

    @State private var matches: [String] = []
    @State private var newEntry = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matches, id: \.self) { Text($0).font(MotifTheme.Typography.body.monospaced()) }
                        .onDelete { matches.remove(atOffsets: $0) }
                    HStack {
                        TextField("Program name (e.g. claude)", text: $newEntry)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addEntry)
                        Button("Add", action: addEntry)
                            .disabled(normalized(newEntry) == nil)
                    }
                } footer: {
                    Text("Compared against the running program's name (path basename of the first token).")
                }
            }
            .navigationTitle("Matched programs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading)  { Button("Cancel") { onCancel() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { onSubmit(matches) } }
            }
            .onAppear { matches = initial }
        }
    }

    private func addEntry() {
        guard let k = normalized(newEntry), !matches.contains(k) else { return }
        matches.append(k)
        newEntry = ""
    }

    private func normalized(_ s: String) -> String? {
        QuickCommandStore.programKey(s.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Per-row editor (snippet add + edit any existing row)

private struct QuickCommandRowEditor: View {
    let initial: QuickCommand?
    let onSubmit: (QuickCommand) -> Void
    let onCancel: () -> Void

    @State private var label: String = ""
    @State private var symbol: String = ""
    @State private var payloadText: String = ""
    @State private var sendImmediately: Bool = true
    @State private var modCtrl = false
    @State private var modAlt = false
    @State private var modShift = false

    var body: some View {
        NavigationStack {
            Form {
                SnippetFields(
                    label: $label, symbol: $symbol, payloadText: $payloadText,
                    sendImmediately: $sendImmediately,
                    modCtrl: $modCtrl, modAlt: $modAlt, modShift: $modShift
                )
            }
            .navigationTitle(initial == nil ? "New snippet" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onCancel() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { submit() }
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let initial {
                    label = initial.label
                    symbol = initial.symbol ?? ""
                    payloadText = qcDecode(initial.payload)
                    sendImmediately = initial.sendImmediately
                    modCtrl = initial.modifiers.contains(.ctrl)
                    modAlt = initial.modifiers.contains(.alt)
                    modShift = initial.modifiers.contains(.shift)
                }
            }
        }
    }

    private func submit() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var modifiers: QuickCommandModifiers = []
        if modCtrl  { modifiers.insert(.ctrl) }
        if modAlt   { modifiers.insert(.alt) }
        if modShift { modifiers.insert(.shift) }
        let cmd = QuickCommand(
            id: initial?.id ?? UUID(),
            label: trimmed,
            symbol: symbol.trimmingCharacters(in: .whitespaces).isEmpty ? nil : symbol,
            payload: qcEncode(payloadText),
            sendImmediately: sendImmediately,
            modifiers: modifiers
        )
        onSubmit(cmd)
    }
}

/// Interpret the small set of escapes (\\n / \\t / \\r / \\e) so the user can
/// type "ls\\n" in the field and have it actually send `ls<LF>`. Anything else
/// passes through as raw UTF-8. Shared by the add sheet and the row editor.
private func qcEncode(_ s: String) -> Data {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "\\", let next = s.index(i, offsetBy: 1, limitedBy: s.endIndex), next < s.endIndex {
            switch s[next] {
            case "n":  out.append(0x0A); i = s.index(after: next); continue
            case "t":  out.append(0x09); i = s.index(after: next); continue
            case "r":  out.append(0x0D); i = s.index(after: next); continue
            case "e":  out.append(0x1B); i = s.index(after: next); continue
            case "\\": out.append(0x5C); i = s.index(after: next); continue
            default: break
            }
        }
        out.append(contentsOf: Array(String(c).utf8))
        i = s.index(after: i)
    }
    return Data(out)
}

/// Round-trip back into the editor — show printable bytes verbatim, escape
/// control bytes `qcEncode` knows about, hex-escape the rest.
private func qcDecode(_ data: Data) -> String {
    var out = ""
    for b in data {
        switch b {
        case 0x0A: out += "\\n"
        case 0x09: out += "\\t"
        case 0x0D: out += "\\r"
        case 0x1B: out += "\\e"
        case 0x5C: out += "\\\\"
        case 0x20...0x7E: out.append(Character(UnicodeScalar(b)))
        default:   out += String(format: "\\x%02x", b)
        }
    }
    return out
}
