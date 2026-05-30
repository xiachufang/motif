import SwiftUI
import OSLog
import TalkerMacro

/// Git-diff page. Mirrors web/src/tabs/DiffTab.tsx in spirit:
///   - layout switch: All (every file concatenated) vs Single (one file
///     at a time, navigate via the Files sheet)
///   - Working ↔ Staged segmented toggle
///   - a Files sheet listing every changed file in List or Tree mode;
///     tapping a file selects it (Single layout) or scrolls to the top
///   - native unified rendering, no diff2html / split view
///
/// Reachable through CmRouter as `/diff` — the session-page toolbar's
/// "diff" button calls `GitDiffPanel.route(...)` and `router.push`es the
/// result.
struct GitDiffPanel: View {
    @Environment(MotifClient.self) private var motif

    let sessionName: String
    let cwd: String?

    private let log = Logger(subsystem: "io.allsunday.motif", category: "GitDiffPanel")

    @State private var staged: Bool = false
    @State private var layout: Layout = .byfile
    @State private var loading: Bool = false
    @State private var error: String?
    @State private var files: [DiffParser.FileDiff] = []
    @State private var selected: Int = 0
    @State private var showingFileList: Bool = false
    @State private var fileListMode: FileListMode = .list
    /// Authoritative per-file additions/deletions from `git.diffSummary`.
    /// Cheaper than parsing the full unified patch and (more importantly)
    /// correct on edge cases the regex parser misses — e.g. renames where
    /// the patch text only contains `similarity index`. The diff itself
    /// still drives the line-by-line rendering; this only enriches the
    /// counts shown in the file list sheet and the global summary row.
    @State private var summaryByPath: [String: (Int, Int)] = [:]

    enum FileListMode: String { case list, tree }
    enum Layout: String, Hashable { case all, byfile }

    @Routable("/diff")
    init(name: String, cwd: String? = nil) {
        self.sessionName = name
        self.cwd = cwd
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            contentArea
        }
        .navigationTitle("Git Diff")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFileList = true
                } label: {
                    Label("\(files.count)", systemImage: "list.bullet.indent")
                }
                .disabled(files.count <= 1)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task(id: staged) { await load() }
        .onChange(of: files.count) { _, n in
            if selected >= n { selected = 0 }
        }
        .onChange(of: motif.gitChangeTick) { _, _ in
            Task { await load() }
        }
        .sheet(isPresented: $showingFileList) {
            DiffFileListSheet(
                files: files,
                summaryByPath: summaryByPath,
                selected: selected,
                mode: $fileListMode,
                onSelect: { i in
                    selected = i
                    showingFileList = false
                }
            )
        }
    }

    /// Toolbar.principal slot is taken by the session route's nav bar,
    /// so we host the staged + layout segmented controls in an inline
    /// header right under the nav bar.
    private var modeBar: some View {
        HStack(spacing: MotifTheme.Spacing.md) {
            Picker("", selection: $staged) {
                Text("Working").tag(false)
                Text("Staged").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)

            Picker("", selection: $layout) {
                Text("All").tag(Layout.all)
                Text("Single").tag(Layout.byfile)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 140)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MotifTheme.Spacing.md)
        .padding(.vertical, MotifTheme.Spacing.sm)
        .background(MotifTheme.textPrimary.opacity(0.08))
    }

    @ViewBuilder
    private var contentArea: some View {
        if loading {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            failureView(error)
        } else if files.isEmpty {
            Text("(no changes)")
                .foregroundStyle(MotifTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            diffList
        }
    }

    private var diffList: some View {
        // ScrollViewReader so .all mode can scroll the picked file into
        // view when the user selects from the Files sheet. .byfile mode
        // just shows files[selected] alone — no scroll needed.
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: MotifTheme.Spacing.lg) {
                    summaryRow
                    switch layout {
                    case .byfile:
                        if files.indices.contains(selected) {
                            fileBlock(files[selected])
                                .id(selected)
                        }
                    case .all:
                        ForEach(Array(files.enumerated()), id: \.offset) { i, f in
                            fileBlock(f)
                                .id("all-\(i)")
                        }
                    }
                }
                .padding(MotifTheme.Spacing.md)
            }
            .background(MotifTheme.background)
            .onChange(of: selected) { _, new in
                if layout == .all, files.indices.contains(new) {
                    withAnimation { proxy.scrollTo("all-\(new)", anchor: .top) }
                }
            }
            .onChange(of: layout) { _, _ in
                if layout == .all, files.indices.contains(selected) {
                    // Defer one tick so the LazyVStack has built the
                    // target row's anchor before we ask to scroll.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        withAnimation { proxy.scrollTo("all-\(selected)", anchor: .top) }
                    }
                }
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: MotifTheme.Spacing.md) {
            Text(summaryBadge)
                .padding(.horizontal, MotifTheme.Spacing.sm).padding(.vertical, 3)
                .background(MotifTheme.textPrimary.opacity(0.18), in: Capsule())
            let (totalAdd, totalDel) = totalCounts()
            // .green / .red here and below are semantic git statuses, intentionally
            // outside the brand palette so adds/removes read the same as in every
            // other diff UI on the planet.
            if totalAdd > 0 { Text("+\(totalAdd)").foregroundStyle(.green) }
            if totalDel > 0 { Text("−\(totalDel)").foregroundStyle(.red) }
            Spacer()
        }
        .font(MotifTheme.Typography.callout.monospaced())
    }

    /// Sum across every file, preferring the server's `git.diffSummary`
    /// counts when available and falling back to the patch parser when
    /// the summary endpoint is empty (e.g., not a git repo).
    private func totalCounts() -> (Int, Int) {
        if !summaryByPath.isEmpty {
            return summaryByPath.values.reduce((0, 0)) { acc, kv in
                (acc.0 + kv.0, acc.1 + kv.1)
            }
        }
        return files.reduce((0, 0)) { ($0.0 + $1.additions, $0.1 + $1.deletions) }
    }

    private var summaryBadge: String {
        switch layout {
        case .byfile: return "\(selected + 1) / \(files.count)"
        case .all:    return "\(files.count) file\(files.count == 1 ? "" : "s")"
        }
    }

    @ViewBuilder
    private func fileBlock(_ f: DiffParser.FileDiff) -> some View {
        let (add, del) = summaryByPath[f.displayPath] ?? (f.additions, f.deletions)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MotifTheme.Spacing.sm) {
                StatusBadge(status: f.status)
                Text(f.displayPath)
                    .font(MotifTheme.Typography.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if add > 0 { Text("+\(add)").foregroundStyle(.green).font(MotifTheme.Typography.caption.monospaced()) }
                if del > 0 { Text("−\(del)").foregroundStyle(.red).font(MotifTheme.Typography.caption.monospaced()) }
            }
            .padding(.horizontal, MotifTheme.Spacing.sm).padding(.vertical, 6)
            .background(MotifTheme.textPrimary.opacity(0.15))

            if f.isBinary {
                Text("Binary file — no textual diff")
                    .font(MotifTheme.Typography.caption).foregroundStyle(MotifTheme.textSecondary)
                    .padding(MotifTheme.Spacing.sm)
            } else if f.lines.isEmpty {
                Text("(empty diff)")
                    .font(MotifTheme.Typography.caption).foregroundStyle(MotifTheme.textSecondary)
                    .padding(MotifTheme.Spacing.sm)
            } else {
                ForEach(Array(f.lines.enumerated()), id: \.offset) { _, line in
                    diffLineView(line)
                }
            }
        }
        .background(MotifTheme.textPrimary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func diffLineView(_ line: DiffParser.DiffLine) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(MotifTheme.Typography.footnote.monospaced())
            .foregroundStyle(lineFg(line.kind))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MotifTheme.Spacing.sm).padding(.vertical, 1)
            .background(lineBg(line.kind))
            .textSelection(.enabled)
    }

    // Diff-line backgrounds and foregrounds are semantic git colours (the
    // universal +green/-red/hunk-blue palette) rather than the brand palette
    // by design — they need to read the same as in every other diff viewer.
    private func lineBg(_ k: DiffParser.DiffLine.Kind) -> Color {
        switch k {
        case .add:    return Color.green.opacity(0.18)
        case .remove: return Color.red.opacity(0.18)
        case .hunk:   return Color.blue.opacity(0.10)
        case .context, .meta: return .clear
        }
    }

    private func lineFg(_ k: DiffParser.DiffLine.Kind) -> Color {
        switch k {
        case .add:    return .green
        case .remove: return .red
        case .hunk:   return .blue
        case .meta:   return MotifTheme.textSecondary
        case .context: return MotifTheme.textPrimary
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: MotifTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(MotifTheme.Typography.symbol(size: 28))
                // Warning hue — not in the brand palette by design.
                .foregroundStyle(.yellow)
            Text(message).font(MotifTheme.Typography.callout).foregroundStyle(MotifTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MotifTheme.Spacing.xl)
            Button("Retry") { Task { await load() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        // Run patch + summary concurrently. The summary endpoint can fail
        // independently (NotAGitRepo, etc.); we tolerate a missing summary
        // and fall back to the parser counts.
        async let patchTask    = motif.gitDiff(path: nil, staged: staged, cwd: cwd)
        async let summaryTask  = motif.gitDiffSummary(path: nil, staged: staged, cwd: cwd)
        do {
            let patch = try await patchTask
            files = DiffParser.parse(patch)
            // Toggling staged ↔ working changes the file set; jumping the
            // selection back to the top is less surprising than holding
            // an index that may now point at a different file.
            selected = 0
        } catch {
            log.error("git.diff: \(String(describing: error), privacy: .public)")
            self.error = "git.diff: \(error)"
            files = []
        }
        if let summary = try? await summaryTask {
            var dict: [String: (Int, Int)] = [:]
            for s in summary { dict[s.path] = (Int(s.additions), Int(s.deletions)) }
            summaryByPath = dict
        } else {
            summaryByPath = [:]
        }
    }
}

/// Minimal unified-diff parser. Splits a `git diff` patch into per-file
/// blocks and classifies each line so the view can color +/-/hunk lines.
/// Renames/copies and binary diffs are detected; the actual diff text
/// preceding a `Binary files differ` line is empty by definition.
enum DiffParser {
    enum FileStatus {
        case modified, added, deleted, renamed, copied, binary, mode
    }

    struct DiffLine {
        enum Kind { case context, add, remove, hunk, meta }
        let kind: Kind
        let text: String
    }

    struct FileDiff {
        let path: String
        let oldPath: String?
        let newPath: String?
        let status: FileStatus
        let additions: Int
        let deletions: Int
        let lines: [DiffLine]
        let isBinary: Bool
        var displayPath: String {
            if status == .renamed || status == .copied,
               let o = oldPath, let n = newPath, o != n {
                return "\(o) → \(n)"
            }
            return path
        }
    }

    static func parse(_ patch: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var cur: Builder?
        let allLines = patch.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        for raw in allLines {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                if let b = cur { files.append(b.build()) }
                cur = Builder(header: line)
                continue
            }
            cur?.feed(line)
        }
        if let b = cur { files.append(b.build()) }
        return files
    }

    private final class Builder {
        var oldPath: String?
        var newPath: String?
        var status: FileStatus = .modified
        var lines: [DiffLine] = []
        var additions = 0
        var deletions = 0
        var isBinary = false
        var inHunk = false

        init(header: String) {
            // `diff --git a/<old> b/<new>` — stash a tentative path; the
            // ---/+++ lines below override it more reliably for renames.
            let parts = header.split(separator: " ").map(String.init)
            if parts.count >= 4 {
                oldPath = stripPrefix(parts[2], "a/")
                newPath = stripPrefix(parts[3], "b/")
            }
        }

        func feed(_ line: String) {
            // Pre-hunk metadata lines (index, mode change, rename info) +
            // the ---/+++ pair. We detect status from these and stash them
            // as `meta` so they render dimly without affecting the +/-
            // counters below.
            if !inHunk {
                if line.hasPrefix("new file mode")     { status = .added }
                else if line.hasPrefix("deleted file") { status = .deleted }
                else if line.hasPrefix("rename ")      { status = .renamed }
                else if line.hasPrefix("copy ")        { status = .copied }
                else if line.contains("Binary files") {
                    status = .binary
                    isBinary = true
                }
                if line.hasPrefix("--- ") {
                    if line == "--- /dev/null" { status = .added }
                    else { oldPath = stripPrefix(String(line.dropFirst(4)), "a/") }
                    lines.append(DiffLine(kind: .meta, text: line))
                    return
                }
                if line.hasPrefix("+++ ") {
                    if line == "+++ /dev/null" { status = .deleted }
                    else { newPath = stripPrefix(String(line.dropFirst(4)), "b/") }
                    lines.append(DiffLine(kind: .meta, text: line))
                    return
                }
                if line.hasPrefix("@@") {
                    inHunk = true
                    lines.append(DiffLine(kind: .hunk, text: line))
                    return
                }
                // Anything else before the first hunk is meta.
                lines.append(DiffLine(kind: .meta, text: line))
                return
            }
            // Inside a hunk.
            if line.hasPrefix("@@") {
                lines.append(DiffLine(kind: .hunk, text: line))
                return
            }
            if line.hasPrefix("+") {
                additions += 1
                lines.append(DiffLine(kind: .add, text: line))
                return
            }
            if line.hasPrefix("-") {
                deletions += 1
                lines.append(DiffLine(kind: .remove, text: line))
                return
            }
            // Context (' ' prefix) or trailing "\ No newline at end of file"
            if line.hasPrefix("\\") {
                lines.append(DiffLine(kind: .meta, text: line))
            } else {
                lines.append(DiffLine(kind: .context, text: line))
            }
        }

        func build() -> FileDiff {
            let path = newPath ?? oldPath ?? "(unknown)"
            return FileDiff(
                path: path,
                oldPath: oldPath,
                newPath: newPath,
                status: status,
                additions: additions,
                deletions: deletions,
                lines: lines,
                isBinary: isBinary
            )
        }
    }

    private static func stripPrefix(_ s: String, _ prefix: String) -> String {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    }
}

extension DiffParser.FileStatus {
    var glyph: String {
        switch self {
        case .added:    return "A"
        case .deleted:  return "D"
        case .modified: return "M"
        case .renamed:  return "R"
        case .copied:   return "C"
        case .binary:   return "B"
        case .mode:     return "·"
        }
    }
    var tint: Color {
        switch self {
        case .added:                  return .green
        case .deleted:                return .red
        case .modified:               return .yellow
        case .renamed, .copied:       return .blue
        case .binary, .mode:          return .secondary
        }
    }
}

/// Single-glyph status pill, shared by the diff body header and the
/// Files sheet rows so they stay visually consistent.
struct StatusBadge: View {
    let status: DiffParser.FileStatus
    var body: some View {
        Text(status.glyph)
            .font(MotifTheme.Typography.caption.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(status.tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(status.tint)
    }
}

// MARK: - Files sheet (list / tree)

/// Sheet listing every file in the current diff. Toggle between flat
/// alphabetical list and a directory tree (single-child compaction
/// matches web/src/tabs/DiffTab.tsx::compactDirs). Tap a file to select
/// it back in the parent panel.
struct DiffFileListSheet: View {
    let files: [DiffParser.FileDiff]
    /// Authoritative `git.diffSummary` counts keyed by display path. Empty
    /// dict means "summary endpoint didn't return; fall back to FileDiff
    /// counts inline".
    var summaryByPath: [String: (Int, Int)] = [:]
    let selected: Int
    @Binding var mode: GitDiffPanel.FileListMode
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var collapsed: Set<String> = []

    private func counts(for f: DiffParser.FileDiff) -> (Int, Int) {
        summaryByPath[f.displayPath] ?? (f.additions, f.deletions)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .list: listMode
                case .tree: treeMode
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $mode) {
                        Text("List").tag(GitDiffPanel.FileListMode.list)
                        Text("Tree").tag(GitDiffPanel.FileListMode.tree)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
            }
        }
    }

    // MARK: list mode

    private var listMode: some View {
        List {
            ForEach(Array(files.enumerated()), id: \.offset) { i, f in
                listRow(index: i, file: f)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(i) }
                    .listRowBackground(i == selected ? MotifTheme.accent.opacity(0.18) : Color.clear)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func listRow(index: Int, file: DiffParser.FileDiff) -> some View {
        let (add, del) = counts(for: file)
        HStack(spacing: 6) {
            StatusBadge(status: file.status)
            Text(file.displayPath)
                .font(MotifTheme.Typography.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if add > 0 { Text("+\(add)").foregroundStyle(.green).font(MotifTheme.Typography.caption.monospaced()) }
            if del > 0 { Text("−\(del)").foregroundStyle(.red).font(MotifTheme.Typography.caption.monospaced()) }
        }
    }

    // MARK: tree mode

    private var treeMode: some View {
        let root = DiffTree.build(files)
        let rows = DiffTree.flatten(root, collapsed: collapsed)
        return List {
            ForEach(rows, id: \.id) { row in
                treeRow(row)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        switch row.kind {
                        case .dir(_, let path, _):
                            if collapsed.contains(path) { collapsed.remove(path) }
                            else { collapsed.insert(path) }
                        case .file(let i, _):
                            onSelect(i)
                        }
                    }
                    .listRowBackground(rowBg(row))
            }
        }
        .listStyle(.plain)
    }

    private func rowBg(_ row: DiffTree.Row) -> Color {
        if case .file(let i, _) = row.kind, i == selected {
            return MotifTheme.accent.opacity(0.18)
        }
        return .clear
    }

    @ViewBuilder
    private func treeRow(_ row: DiffTree.Row) -> some View {
        switch row.kind {
        case .dir(let name, _, let isOpen):
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(row.depth) * 14)
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(MotifTheme.Typography.caption).foregroundStyle(MotifTheme.textSecondary)
                    .frame(width: 12)
                Image(systemName: "folder").foregroundStyle(.tint)
                Text("\(name)/")
                    .font(MotifTheme.Typography.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        case .file(_, let f):
            let (add, del) = counts(for: f)
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(row.depth) * 14 + 12)
                StatusBadge(status: f.status)
                Text(basename(f.displayPath))
                    .font(MotifTheme.Typography.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: MotifTheme.Spacing.xs)
                if add > 0 { Text("+\(add)").foregroundStyle(.green).font(MotifTheme.Typography.caption.monospaced()) }
                if del > 0 { Text("−\(del)").foregroundStyle(.red).font(MotifTheme.Typography.caption.monospaced()) }
            }
        }
    }

    private func basename(_ p: String) -> String {
        // Renamed display = "old → new"; show the new path's basename.
        let primary: String
        if let arrow = p.range(of: " → ") {
            primary = String(p[arrow.upperBound...])
        } else {
            primary = p
        }
        if let slash = primary.lastIndex(of: "/") {
            return String(primary[primary.index(after: slash)...])
        }
        return primary
    }
}

// MARK: - Tree builder

/// Hierarchical view of the patch's file paths. Mirrors web's
/// buildTree → compactDirs → sortTree pipeline so a chain of single-child
/// directories renders as `foo/bar/baz/` on one row.
enum DiffTree {
    final class Dir {
        var name: String
        var path: String
        var children: [Node] = []
        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }
    enum Node {
        case file(index: Int, file: DiffParser.FileDiff)
        case dir(Dir)
    }

    struct Row {
        let id: String
        let depth: Int
        let kind: Kind
        enum Kind {
            case dir(name: String, path: String, isOpen: Bool)
            case file(index: Int, file: DiffParser.FileDiff)
        }
    }

    static func build(_ files: [DiffParser.FileDiff]) -> Dir {
        let root = Dir(name: "", path: "")
        for (idx, f) in files.enumerated() {
            let segments = f.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            if segments.isEmpty {
                root.children.append(.file(index: idx, file: f))
                continue
            }
            var cursor = root
            // Walk all but the last segment, creating dirs as needed.
            for i in 0..<(segments.count - 1) {
                let seg = segments[i]
                let childPath = cursor.path.isEmpty ? seg : "\(cursor.path)/\(seg)"
                if let existing = findChildDir(cursor, name: seg) {
                    cursor = existing
                } else {
                    let nd = Dir(name: seg, path: childPath)
                    cursor.children.append(.dir(nd))
                    cursor = nd
                }
            }
            cursor.children.append(.file(index: idx, file: f))
        }
        compact(root)
        sort(root)
        return root
    }

    private static func findChildDir(_ node: Dir, name: String) -> Dir? {
        for c in node.children {
            if case .dir(let d) = c, d.name == name { return d }
        }
        return nil
    }

    /// Squash chains of single-dir children into a single node so the
    /// tree shows `src/auth/handlers/` instead of three nested rows when
    /// no other files live in the intermediate dirs.
    private static func compact(_ node: Dir) {
        for c in node.children {
            if case .dir(let d) = c { compact(d) }
        }
        if node.path.isEmpty { return }    // never compact the synthetic root
        while node.children.count == 1, case .dir(let only) = node.children[0] {
            node.name = "\(node.name)/\(only.name)"
            node.path = only.path
            node.children = only.children
        }
    }

    private static func sort(_ node: Dir) {
        node.children.sort { a, b in
            switch (a, b) {
            case (.dir, .file): return true
            case (.file, .dir): return false
            case (.dir(let la), .dir(let lb)):
                return la.name.localizedCaseInsensitiveCompare(lb.name) == .orderedAscending
            case (.file(_, let fa), .file(_, let fb)):
                return fa.path.localizedCaseInsensitiveCompare(fb.path) == .orderedAscending
            }
        }
        for c in node.children {
            if case .dir(let d) = c { sort(d) }
        }
    }

    static func flatten(_ root: Dir, collapsed: Set<String>) -> [Row] {
        var out: [Row] = []
        func walk(_ node: Dir, _ depth: Int) {
            for child in node.children {
                switch child {
                case .dir(let d):
                    let open = !collapsed.contains(d.path)
                    out.append(Row(
                        id: "d:\(d.path)",
                        depth: depth,
                        kind: .dir(name: d.name, path: d.path, isOpen: open)
                    ))
                    if open { walk(d, depth + 1) }
                case .file(let i, let f):
                    out.append(Row(
                        id: "f:\(i)",
                        depth: depth,
                        kind: .file(index: i, file: f)
                    ))
                }
            }
        }
        walk(root, 0)
        return out
    }
}
