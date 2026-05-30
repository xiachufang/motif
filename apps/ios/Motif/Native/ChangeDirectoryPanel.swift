import SwiftUI
import OSLog

/// Directory picker for `cd`, VSCode Cmd+P style. A single always-focused
/// path field is the whole interface: the text after the last path separator
/// is a live regex filter over the current directory's subdirectories.
///
///   - Type → filter `baseDir`'s children (case-insensitive regex).
///   - Return → complete into the first candidate.
///   - Tap a candidate → complete into it (the field becomes "<dir>/").
///   - Backspace past a separator → naturally re-lists the parent level.
///   - "↑ Up" → jump to the parent.
///   - Confirm → `cd` to the full path in the field, enabled only when it
///     resolves to a real directory.
///
/// Path decomposition uses Foundation's `NSString` path APIs rather than
/// hand-splitting on "/". Each directory's children are fetched lazily via
/// `fs.tree` depth=1 (the server returns one level per call) and cached; a
/// present cache entry also means "this directory exists / listed
/// successfully", which drives the confirm button's validity.
struct ChangeDirectoryPanel: View {
    @Environment(MotifClient.self) private var motif
    @Environment(\.dismiss) private var dismiss

    let initialPath: String
    let onConfirm: (String) -> Void
    private let log = Logger(subsystem: "io.allsunday.motif", category: "ChangeDirectoryPanel")

    @State private var input: String = ""
    /// directory path → its subdirectories. Presence ⇒ the dir exists and was
    /// listed; absence (after a load attempt) ⇒ unreadable.
    @State private var cache: [String: [MotifProto.TreeEntry]] = [:]
    @State private var loading: Set<String> = []
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pathField
                Divider()
                candidateList
            }
            .navigationTitle("Change directory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { confirmBar }
        }
        .task {
            input = asDirectoryPath(initialPath)
            focused = true
            await load(baseDir)
        }
        .onChange(of: baseDir) { _, newBase in
            Task { await load(newBase) }
        }
    }

    // MARK: - Subviews

    private var pathField: some View {
        HStack(spacing: 8) {
            // Terminal-prompt glyph signals "this is a path you type into".
            Image(systemName: "chevron.right")
                .font(MotifTheme.Typography.callout.bold())
                .foregroundStyle(.tint)
            TextField("path", text: $input)
                .font(MotifTheme.Typography.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.go)
                .onSubmit { enterFirst() }
            if loading.contains(baseDir) {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 12)
    }

    private var candidateList: some View {
        List {
            if baseDir != "/" {
                parentRow
            }
            if candidates.isEmpty, cache[baseDir] != nil, !loading.contains(baseDir) {
                Text(query.isEmpty ? "No subdirectories" : "No match")
                    .font(MotifTheme.Typography.footnote)
                    .foregroundStyle(MotifTheme.textSecondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(candidates.enumerated()), id: \.element.id) { idx, entry in
                dirRow(name: entry.name, isFirst: idx == 0)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(idx == 0 ? Color.accentColor.opacity(0.12) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { drill(into: entry.name) }
            }
        }
        .listStyle(.plain)
    }

    /// Go-to-parent row, styled distinctly from real subdirectories.
    private var parentRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(MotifTheme.textSecondary)
                .frame(width: 22)
            Text("..")
                .font(MotifTheme.Typography.body.monospaced().weight(.medium))
            Text("parent")
                .font(MotifTheme.Typography.caption)
                .foregroundStyle(MotifTheme.textTertiary)
            Spacer()
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .contentShape(Rectangle())
        .onTapGesture { goUp() }
    }

    /// A subdirectory candidate. The first one is the Return target, marked
    /// with a ↵ glyph; the trailing chevron signals "tap to go in".
    private func dirRow(name: String, isFirst: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(name)
                .font(MotifTheme.Typography.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if isFirst {
                Image(systemName: "return")
                    .font(MotifTheme.Typography.caption.bold())
                    .foregroundStyle(.tint)
            }
            Image(systemName: "chevron.right")
                .font(MotifTheme.Typography.caption)
                .foregroundStyle(MotifTheme.textTertiary)
        }
    }

    private var confirmBar: some View {
        Button {
            if let target = resolvedTarget {
                onConfirm(target)
                dismiss()
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(MotifTheme.Typography.callout)
                // "cd" stays fixed; the path truncates from the front so the
                // tail (the directory you're entering) is always visible.
                Text("cd").font(MotifTheme.Typography.callout.monospaced())
                Text(displayPath)
                    .font(MotifTheme.Typography.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(MotifButtonStyle(role: .filled, size: .medium))
        .disabled(resolvedTarget == nil)
        .padding(MotifTheme.Spacing.lg)
    }

    // MARK: - Derived state

    /// The directory whose children we list and filter. A trailing separator
    /// in the field means "inside this dir"; otherwise the last component is a
    /// partial leaf being typed, so the directory is its parent.
    private var baseDir: String {
        if input.hasSuffix("/") {
            return withoutTrailingSeparator(input)
        }
        return (input as NSString).deletingLastPathComponent
    }

    /// The partial leaf being typed: the live filter for `baseDir`'s children.
    /// Empty when the field ends in a separator.
    private var query: String {
        input.hasSuffix("/") ? "" : (input as NSString).lastPathComponent
    }

    /// Path shown on the confirm button — the full text the user would cd to.
    private var displayPath: String {
        resolvedTarget ?? withoutTrailingSeparator(input)
    }

    private var candidates: [MotifProto.TreeEntry] {
        let all = cache[baseDir] ?? []
        guard !query.isEmpty else { return all }
        let matches = matcher(for: query)
        return all
            .filter { matches($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Case-insensitive regex matcher (search semantics — matches anywhere
    /// unless anchored). Falls back to a literal case-insensitive substring
    /// match while the pattern is incomplete/invalid (e.g. a lone "(" or "[")
    /// so the list doesn't blank out mid-typing.
    private func matcher(for pattern: String) -> (String) -> Bool {
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            return { name in
                regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
        }
        let q = pattern.lowercased()
        return { $0.lowercased().contains(q) }
    }

    /// The directory the confirm button targets, or nil when the field doesn't
    /// resolve to a real directory (button disabled).
    private var resolvedTarget: String? {
        if query.isEmpty {
            // Field ends with a separator: baseDir must have listed OK.
            guard cache[baseDir] != nil else { return nil }
            return baseDir
        }
        // Partial leaf: valid only when it exactly matches a child dir name
        // (case-insensitive); the target uses the child's real-case name.
        guard let match = (cache[baseDir] ?? []).first(where: {
            $0.name.lowercased() == query.lowercased()
        }) else { return nil }
        return (baseDir as NSString).appendingPathComponent(match.name)
    }

    // MARK: - Actions

    private func enterFirst() {
        guard let first = candidates.first else { return }
        drill(into: first.name)
    }

    private func drill(into name: String) {
        input = asDirectoryPath((baseDir as NSString).appendingPathComponent(name))
        focused = true
    }

    private func goUp() {
        guard baseDir != "/" else { return }
        input = asDirectoryPath((baseDir as NSString).deletingLastPathComponent)
        focused = true
    }

    private func load(_ dir: String, force: Bool = false) async {
        guard !dir.isEmpty else { return }
        if !force && cache[dir] != nil { return }
        if loading.contains(dir) { return }
        loading.insert(dir)
        defer { loading.remove(dir) }
        do {
            let r = try await motif.fsTree(path: dir, depth: 1, showHidden: false)
            cache[dir] = r.entries
                .filter { $0.type == .dir }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            // Leave cache[dir] unset → treated as "does not exist / unreadable",
            // so the confirm button stays disabled for this path.
            log.error("fs.tree(\(dir, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Path helpers

    /// A directory path the field should show: ends with a single separator so
    /// it reads as "inside this dir" and `query` resolves to empty. Root stays
    /// "/".
    private func asDirectoryPath(_ p: String) -> String {
        if p.isEmpty || p == "/" { return "/" }
        return p.hasSuffix("/") ? p : p + "/"
    }

    /// Drop a single trailing separator (keep root "/").
    private func withoutTrailingSeparator(_ p: String) -> String {
        (p.count > 1 && p.hasSuffix("/")) ? String(p.dropLast()) : p
    }
}
