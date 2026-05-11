import SwiftUI

/// Modal editor for the BottomInputBar's quick-command list. Reorder via
/// drag handles, swipe-to-delete, tap a row to edit it, or "+" to add a
/// new entry (special key from the predefined enum, or a free-form text
/// snippet). All mutations go through `QuickCommandStore` which
/// re-persists immediately.
struct QuickCommandEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var addType: AddType?
    @State private var editing: QuickCommand?

    private enum AddType: Identifiable {
        case key, snippet
        var id: String { self == .key ? "key" : "snippet" }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(appState.commands.commands) { cmd in
                    Button {
                        editing = cmd
                    } label: {
                        row(cmd)
                    }
                    .buttonStyle(.plain)
                }
                .onMove { from, to in appState.commands.move(from: from, to: to) }
                .onDelete { offsets in appState.commands.remove(at: offsets) }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Quick commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            addType = .key
                        } label: { Label("Special key", systemImage: "keyboard") }
                        Button {
                            addType = .snippet
                        } label: { Label("Text snippet", systemImage: "text.cursor") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $addType) { kind in
                switch kind {
                case .key:
                    SpecialKeyPicker { key in
                        appState.commands.add(key.makeCommand())
                        addType = nil
                    } onCancel: { addType = nil }
                case .snippet:
                    QuickCommandRowEditor(initial: nil) { cmd in
                        appState.commands.add(cmd)
                        addType = nil
                    } onCancel: { addType = nil }
                }
            }
            .sheet(item: $editing) { cmd in
                QuickCommandRowEditor(initial: cmd) { updated in
                    appState.commands.update(updated)
                    editing = nil
                } onCancel: { editing = nil }
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
                Text(payloadPreview(cmd.payload))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: cmd.sendImmediately ? "paperplane.fill" : "text.insert")
                .foregroundStyle(.secondary)
                .font(.caption)
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
