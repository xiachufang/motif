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
    @State private var addType: AddType?
    @State private var editing: QuickCommand?
    @State private var showingRename = false
    @State private var renameTarget = ""
    @State private var showingMatches = false

    private enum AddType: Identifiable {
        case key, snippet
        var id: String { self == .key ? "key" : "snippet" }
    }

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
                        addType = .key
                    } label: { Label("Special key", systemImage: "keyboard") }
                    Button {
                        addType = .snippet
                    } label: { Label("Text snippet", systemImage: "text.cursor") }
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
                        appState.commands.add(.cd(), to: scope)
                    } label: { Label("Change directory", systemImage: "arrow.turn.down.right") }
                        .disabled(items.contains { $0.kind == .cd })
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $addType) { kind in
            switch kind {
            case .key:
                SpecialKeyPicker { key in
                    appState.commands.add(key.makeCommand(), to: scope)
                    addType = nil
                } onCancel: { addType = nil }
            case .snippet:
                QuickCommandRowEditor(initial: nil) { cmd in
                    appState.commands.add(cmd, to: scope)
                    addType = nil
                } onCancel: { addType = nil }
            }
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
                    .font(.caption.bold().monospaced())
                    .frame(width: 20)
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(cmd.label)
                    .font(.body)
                Text(subtitle(cmd))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            // The send/insert glyph only means something for byte payloads.
            if cmd.kind == .bytes {
                Image(systemName: cmd.sendImmediately ? "paperplane.fill" : "text.insert")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    /// Secondary line under the label. Byte commands show their payload;
    /// the special kinds describe their behavior instead of an empty payload.
    private func subtitle(_ cmd: QuickCommand) -> String {
        switch cmd.kind {
        case .paste:      return "clipboard"
        case .ctrl, .alt: return "sticky modifier"
        case .cd:         return "directory picker"
        case .bytes:      return payloadPreview(cmd.payload)
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

private struct SpecialKeyPicker: View {
    let onPick: (QuickCommandKey) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Movement") {
                    keyButton(.esc)
                    keyButton(.tab)
                    keyButton(.enter)
                    keyButton(.up)
                    keyButton(.down)
                    keyButton(.left)
                    keyButton(.right)
                    keyButton(.home)
                    keyButton(.end)
                    keyButton(.pageUp)
                    keyButton(.pageDown)
                }
                Section("Process control") {
                    keyButton(.ctrlC)
                    keyButton(.ctrlD)
                    keyButton(.ctrlZ)
                }
                Section("Editing") {
                    keyButton(.ctrlA); keyButton(.ctrlE); keyButton(.ctrlK); keyButton(.ctrlU); keyButton(.ctrlW); keyButton(.ctrlY)
                }
                Section("Other") {
                    keyButton(.ctrlL); keyButton(.ctrlR); keyButton(.ctrlT)
                    keyButton(.ctrlB); keyButton(.ctrlF)
                    keyButton(.ctrlG); keyButton(.ctrlN); keyButton(.ctrlP)
                }
                Section("Symbols") {
                    keyButton(.pipe); keyButton(.slash); keyButton(.tilde); keyButton(.dash)
                    keyButton(.underscore); keyButton(.backtick); keyButton(.singleQuote); keyButton(.doubleQuote)
                }
            }
            .navigationTitle("Pick a key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onCancel() } }
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: QuickCommandKey) -> some View {
        Button { onPick(key) } label: {
            HStack {
                if let s = key.symbol {
                    Image(systemName: s).frame(width: 22)
                } else {
                    Text(key.label).frame(width: 22, alignment: .leading)
                        .font(.caption.bold().monospaced())
                }
                Text(key.label).foregroundStyle(.primary)
                Spacer()
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
                    ForEach(matches, id: \.self) { Text($0).font(.body.monospaced()) }
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    TextField("Label", text: $label)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("SF Symbol (optional)", text: $symbol)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    TextEditor(text: $payloadText)
                        .font(.system(.body, design: .monospaced))
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
                    payloadText = decode(initial.payload)
                    sendImmediately = initial.sendImmediately
                }
            }
        }
    }

    private func submit() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let payload = encode(payloadText)
        let cmd = QuickCommand(
            id: initial?.id ?? UUID(),
            label: trimmed,
            symbol: symbol.trimmingCharacters(in: .whitespaces).isEmpty ? nil : symbol,
            payload: payload,
            sendImmediately: sendImmediately
        )
        onSubmit(cmd)
    }

    /// Interpret the small set of escapes (\\n / \\t / \\r / \\e) so the
    /// user can type "ls\\n" in the field and have it actually send
    /// `ls<LF>`. Anything else passes through as raw UTF-8.
    private func encode(_ s: String) -> Data {
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

    /// Round-trip back into the editor — show printable bytes verbatim,
    /// escape control bytes that `encode` knows about, hex-escape the rest.
    private func decode(_ data: Data) -> String {
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
}
