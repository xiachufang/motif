import SwiftUI
import OSLog

/// File-tree side panel. Mirrors web/src/panels/FileTree.tsx:
///   - rooted at the active PTY's cwd (passed in)
///   - tap a directory to toggle in-place expansion (no re-rooting)
///   - first expand on a path triggers a lazy `fs.tree` fetch
///   - shows a one-glyph git status badge (M / A / D / ? / U / …)
///
/// Refresh re-pulls the root only — already-expanded subdirs reuse their
/// last fetched children. `tree.changed` event-driven invalidation
/// re-fetches every cached subtree.
struct FileTreePanel: View {
    @Environment(MotifClient.self) private var motif
    @Environment(\.dismiss) private var dismiss

    let rootPath: String
    /// Invoked when the user taps a file row. Caller decides where to
    /// route it (in SessionView this opens a preview tab and dismisses
    /// the sheet).
    let onOpen: (String) -> Void
    private let log = Logger(subsystem: "io.allsunday.motif", category: "FileTreePanel")

    @State private var children: [String: [MotifProto.TreeEntry]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loading: Set<String> = []
    @State private var error: String?
    @State private var prompt: PromptKind?
    @State private var promptText: String = ""

    /// Mutation prompts unify rename / delete / new-file / new-folder so
    /// only one alert binding is alive at a time. `id` is path-prefixed
    /// so a re-prompt on the same path reuses the alert without flicker.
    private enum PromptKind: Identifiable {
        case rename(path: String, current: String)
        case delete(path: String, kind: MotifProto.FileType)
        case newFile(parent: String)
        case newFolder(parent: String)

        var id: String {
            switch self {
            case .rename(let p, _):     return "rn:\(p)"
            case .delete(let p, _):     return "del:\(p)"
            case .newFile(let p):       return "nf:\(p)"
            case .newFolder(let p):     return "nd:\(p)"
            }
        }

        var title: String {
            switch self {
            case .rename:               return "Rename"
            case .delete(_, let kind):  return kind == .dir ? "Delete folder?" : "Delete file?"
            case .newFile:              return "New file"
            case .newFolder:            return "New folder"
            }
        }

        var needsTextInput: Bool {
            if case .delete = self { return false }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let _ = children[rootPath] {
                    treeList
                } else if let error {
                    failureView(error)
                } else {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(basename(rootPath).isEmpty ? "/" : basename(rootPath))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            startPrompt(.newFile(parent: rootPath))
                        } label: { Label("New file", systemImage: "doc.badge.plus") }
                        Button {
                            startPrompt(.newFolder(parent: rootPath))
                        } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load(rootPath, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task { await load(rootPath) }
        .onChange(of: motif.treeChangeTick) { _, _ in
            // Server notified that something on disk changed. Refetch
            // every subtree we still have cached, in parallel-as-async.
            // Conservative — we don't filter by the changed paths list,
            // since the user's expanded set is small.
            Task { await refetchAllCached() }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(
            get: { prompt != nil },
            set: { if !$0 { prompt = nil } }
        )) {
            if let prompt, prompt.needsTextInput {
                TextField("name", text: $promptText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button("Cancel", role: .cancel) { self.prompt = nil }
            confirmButton
        } message: {
            if let prompt {
                Text(promptMessage(prompt))
            }
        }
    }

    @ViewBuilder
    private var confirmButton: some View {
        if let p = prompt {
            switch p {
            case .delete(let path, _):
                Button("Delete", role: .destructive) {
                    Task { await commitDelete(path: path) }
                }
            case .rename(let path, let current):
                Button("Rename") {
                    Task { await commitRename(path: path, oldName: current) }
                }
            case .newFile(let parent):
                Button("Create") {
                    Task { await commitNewFile(parent: parent) }
                }
            case .newFolder(let parent):
                Button("Create") {
                    Task { await commitNewFolder(parent: parent) }
                }
            }
        }
    }

    private func promptMessage(_ p: PromptKind) -> String {
        switch p {
        case .rename(let path, _):     return "Path: \(path)"
        case .delete(let path, let k):
            return k == .dir
                ? "Delete '\(path)' and everything inside it? This cannot be undone."
                : "Delete '\(path)'? This cannot be undone."
        case .newFile(let parent):     return "Create a new empty file in \(parent)"
        case .newFolder(let parent):   return "Create a new folder in \(parent)"
        }
    }

    private var treeList: some View {
        // Flatten the currently-visible portion of the tree into a single
        // list of rows so SwiftUI's List handles selection / scrolling
        // without needing recursive DisclosureGroups (which interact
        // poorly with lazy children).
        let rows = flatten()
        return List {
            ForEach(rows, id: \.path) { row in
                rowView(row)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        switch row.entry.type {
                        case .dir:             Task { await toggleDir(row.path) }
                        case .file, .symlink:  onOpen(row.path)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            startPrompt(.delete(path: row.path, kind: row.entry.type))
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            startPrompt(.rename(path: row.path, current: row.entry.name))
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.plain)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.yellow)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") { Task { await load(rootPath, force: true) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row layout

    private struct Row {
        let path: String
        let entry: MotifProto.TreeEntry
        let depth: Int
    }

    private func flatten() -> [Row] {
        guard let rootEntries = children[rootPath] else { return [] }
        var out: [Row] = []
        func walk(_ parent: String, _ entries: [MotifProto.TreeEntry], _ depth: Int) {
            for e in entries {
                let p = joinPath(parent, e.name)
                out.append(Row(path: p, entry: e, depth: depth))
                if e.type == .dir, expanded.contains(p), let kids = children[p] {
                    walk(p, kids, depth + 1)
                }
            }
        }
        walk(rootPath, rootEntries, 0)
        return out
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(row.depth) * 14)
            chevron(for: row)
            icon(for: row)
            Text(row.entry.type == .dir ? "\(row.entry.name)/" : row.entry.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let badge = statusBadge(row.entry.git_status) {
                Text(badge.glyph)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(badge.color)
            }
            if row.entry.type == .dir, expanded.contains(row.path), loading.contains(row.path) {
                ProgressView().controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func chevron(for row: Row) -> some View {
        if row.entry.type == .dir {
            Image(systemName: expanded.contains(row.path) ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12)
        } else {
            Spacer().frame(width: 12)
        }
    }

    @ViewBuilder
    private func icon(for row: Row) -> some View {
        switch row.entry.type {
        case .dir:     Image(systemName: "folder").foregroundStyle(.tint)
        case .file:    Image(systemName: "doc").foregroundStyle(.secondary)
        case .symlink: Image(systemName: "link").foregroundStyle(.secondary)
        }
    }

    private func statusBadge(_ status: MotifProto.GitFileStatus?) -> (glyph: String, color: Color)? {
        guard let status, status != .unmodified else { return nil }
        switch status {
        case .modified:    return ("M", .yellow)
        case .added:       return ("A", .green)
        case .deleted:     return ("D", .red)
        case .renamed:     return ("R", .blue)
        case .copied:      return ("C", .blue)
        case .untracked:   return ("?", .secondary)
        case .ignored:     return ("!", .secondary)
        case .conflicted:  return ("U", .orange)
        case .unmodified:  return nil
        }
    }

    // MARK: - State transitions

    private func toggleDir(_ path: String) async {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if children[path] == nil {
                await load(path)
            }
        }
    }

    private func refetchAllCached() async {
        let paths = Array(children.keys)
        for p in paths {
            await load(p, force: true)
        }
    }

    private func load(_ path: String, force: Bool = false) async {
        if !force && children[path] != nil { return }
        if loading.contains(path) { return }
        loading.insert(path)
        defer { loading.remove(path) }
        do {
            let r = try await motif.fsTree(path: path, depth: 1, showHidden: false)
            children[path] = r.entries.sorted(by: entryOrder)
            if path == rootPath { error = nil }
        } catch {
            log.error("fs.tree(\(path, privacy: .public)): \(String(describing: error), privacy: .public)")
            if path == rootPath {
                self.error = "fs.tree: \(error)"
            }
        }
    }

    // MARK: - Mutation flow

    private func startPrompt(_ kind: PromptKind) {
        prompt = kind
        switch kind {
        case .rename(_, let current): promptText = current
        case .delete:                 promptText = ""
        case .newFile, .newFolder:    promptText = ""
        }
    }

    private func commitDelete(path: String) async {
        prompt = nil
        do {
            try await motif.fsRemove(path: path)
            await invalidate(parent: parentDir(of: path))
        } catch {
            self.error = "delete: \(error)"
        }
    }

    private func commitRename(path: String, oldName: String) async {
        let newName = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = nil
        guard !newName.isEmpty, !newName.contains("/"), newName != oldName else { return }
        let parent = parentDir(of: path)
        let to = joinPath(parent, newName)
        do {
            try await motif.fsRename(from: path, to: to)
            await invalidate(parent: parent)
        } catch {
            self.error = "rename: \(error)"
        }
    }

    private func commitNewFile(parent: String) async {
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = nil
        guard !name.isEmpty, !name.contains("/") else { return }
        let path = joinPath(parent, name)
        do {
            // Empty body, expected_sha256 == nil → "this file should
            // not exist yet". Server returns Conflict if the path
            // already has content; we surface it as red text.
            _ = try await motif.fsWrite(
                path: path,
                contentB64: "",
                expectedSha256: nil,
                force: false
            )
            await invalidate(parent: parent)
        } catch {
            self.error = "new file: \(error)"
        }
    }

    private func commitNewFolder(parent: String) async {
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = nil
        guard !name.isEmpty, !name.contains("/") else { return }
        let path = joinPath(parent, name)
        do {
            try await motif.fsMkdir(path: path)
            await invalidate(parent: parent)
        } catch {
            self.error = "new folder: \(error)"
        }
    }

    /// Optimistic re-load of the affected directory so the user sees the
    /// result immediately — `tree.changed` will follow and trigger an
    /// idempotent re-load via `refetchAllCached`.
    private func invalidate(parent: String) async {
        await load(parent, force: true)
    }

    // MARK: - Path helpers

    private func joinPath(_ base: String, _ name: String) -> String {
        if base.isEmpty { return name }
        return base.hasSuffix("/") ? base + name : "\(base)/\(name)"
    }

    private func parentDir(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        if let slash = trimmed.lastIndex(of: "/") {
            let parent = String(trimmed[..<slash])
            return parent.isEmpty ? "/" : parent
        }
        return rootPath
    }

    private func basename(_ p: String) -> String {
        let trimmed = p.hasSuffix("/") && p != "/" ? String(p.dropLast()) : p
        if let slash = trimmed.lastIndex(of: "/") {
            let s = String(trimmed[trimmed.index(after: slash)...])
            return s.isEmpty ? "/" : s
        }
        return trimmed
    }

    /// Sort order: dirs first, then files; within each group, lexicographic
    /// case-insensitive. Matches web's intuitive default.
    private func entryOrder(_ a: MotifProto.TreeEntry, _ b: MotifProto.TreeEntry) -> Bool {
        if a.type != b.type {
            return a.type == .dir
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
