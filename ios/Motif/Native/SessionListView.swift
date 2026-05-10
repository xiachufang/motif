import SwiftUI
import TalkerCommonRouter
import TalkerMacro

/// Browse / create / attach to motif sessions. After attach, push the
/// /session route so SessionView takes over.
struct SessionListView: View {
    @Environment(MotifClient.self) private var motif
    @Environment(CmRouter.self) private var router

    @State private var loading: Bool = false
    @State private var error: String?
    @State private var creatingName: String = ""
    @State private var creatingWorkdir: String = "~"
    @State private var attaching: String?
    /// Name of the session the user has asked to destroy. Drives the
    /// confirmation alert; non-nil means "alert is visible". Cleared in
    /// both the OK and Cancel branches.
    @State private var destroyTarget: String?

    var body: some View {
        List {
            Section {
                if motif.sessions.isEmpty && !loading {
                    Text("No sessions on this server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(motif.sessions) { session in
                        Button {
                            Task { await attach(session.name) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.name)
                                        .foregroundStyle(.primary)
                                    if let wd = session.workdir {
                                        Text(wd).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if attaching == session.name {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(attaching != nil)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                destroyTarget = session.name
                            } label: {
                                Label("Destroy", systemImage: "trash")
                            }
                            .disabled(attaching != nil)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.footnote)
                    }
                }
            }

            Section {
                TextField("name", text: $creatingName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("working directory", text: $creatingWorkdir)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                Button("Create + attach") {
                    Task { await createAndAttach() }
                }
                .disabled(!isCreateValid || attaching != nil)
            } header: {
                Text("New session")
            } footer: {
                Text("Working directory must exist on the server. ~ expands to the motifd user's home.")
                    .font(.caption2)
            }

            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .task {
            await refresh()
        }
        .alert("Destroy session?",
               isPresented: Binding(
                   get: { destroyTarget != nil },
                   set: { if !$0 { destroyTarget = nil } })) {
            Button("Destroy", role: .destructive) {
                if let name = destroyTarget {
                    Task { await destroy(name) }
                }
            }
            Button("Cancel", role: .cancel) { destroyTarget = nil }
        } message: {
            if let name = destroyTarget {
                Text("This will kill all PTYs in '\(name)' and disconnect any clients still attached. The action cannot be undone.")
            }
        }
    }

    private func refresh() async {
        loading = true
        error = nil
        await motif.refreshSessions()
        loading = false
    }

    private func attach(_ name: String) async {
        attaching = name
        defer { attaching = nil }
        do {
            try await motif.attach(sessionName: name)
            let (path, query) = SessionView.route(name: name)
            router.push(CmRouterPath(path, query))
        } catch {
            self.error = "attach \(name): \(error)"
        }
    }

    private func createAndAttach() async {
        let name = creatingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let workdir = creatingWorkdir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !workdir.isEmpty else { return }
        attaching = name
        defer { attaching = nil }
        do {
            _ = try await motif.createSession(name: name, workdir: workdir)
            try await motif.attach(sessionName: name)
            creatingName = ""
            creatingWorkdir = "~"
            let (path, query) = SessionView.route(name: name)
            router.push(CmRouterPath(path, query))
        } catch {
            self.error = "create \(name): \(error)"
        }
    }

    private func destroy(_ name: String) async {
        destroyTarget = nil
        do {
            try await motif.destroySession(name: name)
            await refresh()
        } catch {
            self.error = "destroy \(name): \(error)"
        }
    }

    private var isCreateValid: Bool {
        !creatingName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !creatingWorkdir.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Heterogeneous tab kind held in `SessionView`. Each case carries the
/// server-issued ViewId so tab taps route through `view.activate` and
/// stay in sync with web/cast/other clients.
enum SessionTab: Hashable, Identifiable {
    case pty(viewID: String, ptyID: String)
    case preview(viewID: String, path: String)
    case diff(viewID: String, staged: Bool, path: String?)
    case image(viewID: String, path: String)
    case unknown(viewID: String, kind: String)

    var id: String { viewID }

    var viewID: String {
        switch self {
        case .pty(let v, _),
             .preview(let v, _),
             .image(let v, _):                  return v
        case .diff(let v, _, _):                return v
        case .unknown(let v, _):                return v
        }
    }
}

/// After session.attach succeeds, show the tab bar + the active pane.
/// Tabs are derived from `motif.views` — server-mirrored for every kind
/// (pty / preview / diff / image), so opens and closes by any client
/// propagate to every other.
///
/// `@Routable("/session")` makes this view addressable as `/session` via
/// CmRouter. The macro emits `SessionView.path`, `SessionView.route(name:)`
/// for type-safe push, and a `init?(_ data: [String: String])` that
/// `#routeViews` uses on the receiving end.
struct SessionView: View {
    @Environment(MotifClient.self) private var motif
    @Environment(CmRouter.self) private var router
    let name: String
    @State private var error: String?
    @State private var showingTree: Bool = false

    /// Project the server's view list into our heterogeneous tab enum.
    /// Order matches `motif.views`, which the server keeps consistent
    /// across clients via `view.opened` / `view.moved` events.
    private var allTabs: [SessionTab] {
        motif.views.map { v in
            switch v.spec {
            case .pty(let id):           return .pty(viewID: v.id, ptyID: id)
            case .preview(let p):        return .preview(viewID: v.id, path: p)
            case .diff(let s, let p):    return .diff(viewID: v.id, staged: s, path: p)
            case .image(let p):          return .image(viewID: v.id, path: p)
            case .other(let kind):       return .unknown(viewID: v.id, kind: kind)
            }
        }
    }

    /// Active tab is a derived projection over the server's
    /// `activeViewID`. Tap handlers call `motif.activateView` and let
    /// the resulting `view.active_changed` event flow back through
    /// `motif.activeViewID` — no local mirror, no echo loop.
    private var activeTab: SessionTab? {
        guard let id = motif.activeViewID else { return nil }
        return allTabs.first(where: { $0.viewID == id })
    }

    /// cwd of the currently active PTY — used as the file-tree root and
    /// the cwd hint for git.diff so both follow the same shell as the
    /// user navigates with `cd`. When the active tab isn't a PTY (it's a
    /// preview / diff / image), fall back to any PTY with a known cwd
    /// so the file tree and diff button still have a useful default.
    private var activeCwd: String? {
        if case .pty(_, let ptyID) = activeTab,
           let pty = motif.ptys.first(where: { $0.id == ptyID }) {
            return pty.cwd
        }
        return motif.ptys.first(where: { $0.cwd?.isEmpty == false })?.cwd
    }

    @Routable("/session")
    init(name: String) {
        self.name = name
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            paneArea
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .background(Color.black)
        .task {
            // Auto-pick: if the server didn't seed an active view in the
            // attach response and there's no view yet, spawn a PTY (the
            // server auto-opens + activates a view for it). If there IS
            // a server-side active view already (e.g. cast was running
            // on the host), motif.activeViewID handles it for us.
            if motif.activeViewID == nil {
                if let firstPty = motif.views.first(where: {
                    if case .pty = $0.spec { return true } else { return false }
                }) {
                    await motif.activateView(viewID: firstPty.id)
                } else {
                    await spawnPty()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingTree = true
                } label: {
                    Image(systemName: "folder")
                }
                .disabled(activeCwd == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let (path, query) = GitDiffPanel.route(name: name, cwd: activeCwd)
                    router.push(CmRouterPath(path, query))
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
            }
        }
        .sheet(isPresented: $showingTree) {
            if let root = activeCwd, !root.isEmpty {
                FileTreePanel(rootPath: root, onOpen: openPreview)
                    .environment(motif)
            } else {
                Text("No active working directory.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    // MARK: - Tab management

    /// File tree's "open" → server-side preview view. The resulting
    /// `view.opened` + `view.active_changed` events fan out and flip
    /// our derived activeTab to match.
    private func openPreview(_ path: String) {
        showingTree = false
        // Already open? Just re-activate so we don't pay for a duplicate.
        if let existing = motif.views.first(where: {
            if case .preview(let p) = $0.spec, p == path { return true }
            return false
        }) {
            Task { await motif.activateView(viewID: existing.id) }
            return
        }
        Task {
            do {
                _ = try await motif.openView(spec: .preview(path: path), activate: true)
            } catch {
                self.error = "open preview: \(error)"
            }
        }
    }

    private func closeTab(_ tab: SessionTab) {
        Task { await motif.closeView(viewID: tab.viewID) }
    }

    private func activate(_ tab: SessionTab) {
        Task { await motif.activateView(viewID: tab.viewID) }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(allTabs.enumerated()), id: \.element.id) { idx, tab in
                    tabButton(tab: tab, ordinal: idx + 1)
                }
                Button {
                    Task { await spawnPty() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .foregroundStyle(.tint)
            }
            .padding(8)
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func tabButton(tab: SessionTab, ordinal: Int) -> some View {
        let isActive = activeTab == tab
        let closable: Bool = {
            // PTY tabs end via pty.exited, not user close. Other kinds
            // are user-opened and freely closable.
            if case .pty = tab { return false }
            return true
        }()

        HStack(spacing: 4) {
            Button {
                activate(tab)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tabIcon(tab))
                    Text(tabLabel(tab, ordinal: ordinal))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            if closable {
                Button {
                    closeTab(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.white.opacity(0.15) : Color.white.opacity(0.05),
                    in: Capsule())
        .foregroundStyle(.white)
    }

    /// Tab label per kind. PTY label mirrors web/src/panels/TabBar.tsx
    /// (`runningCommand → cwd basename → cmd basename → ordinal`).
    private func tabLabel(_ tab: SessionTab, ordinal: Int) -> String {
        switch tab {
        case .pty(_, let ptyID):
            if let pty = motif.ptys.first(where: { $0.id == ptyID }) {
                return ptyLabel(pty: pty, ordinal: ordinal)
            }
            return "pty"
        case .preview(_, let path):
            return basename(path)
        case .diff(_, let staged, let path):
            if let p = path, !p.isEmpty { return "diff: \(basename(p))" }
            return staged ? "diff (staged)" : "diff"
        case .image(_, let path):
            return basename(path)
        case .unknown(_, let kind):
            return kind.isEmpty ? "view" : kind
        }
    }

    private func tabIcon(_ tab: SessionTab) -> String {
        switch tab {
        case .pty(_, let ptyID):
            if motif.runningCommand[ptyID]?.isEmpty == false { return "play.fill" }
            return "terminal"
        case .preview:                          return "doc.text"
        case .diff:                             return "arrow.triangle.branch"
        case .image:                            return "photo"
        case .unknown:                          return "questionmark.square"
        }
    }

    private func ptyLabel(pty: MotifProto.PtyInfo, ordinal: Int) -> String {
        if let running = motif.runningCommand[pty.id], !running.isEmpty {
            return basename(firstToken(running))
        }
        if let cwd = pty.cwd, !cwd.isEmpty {
            let leaf = basename(cwd)
            if !leaf.isEmpty { return leaf }
        }
        if let cmd = pty.cmd, !cmd.isEmpty {
            let leaf = basename(firstToken(cmd))
            if !leaf.isEmpty { return leaf }
        }
        return String(ordinal)
    }

    private func firstToken(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            return String(trimmed[..<space])
        }
        return trimmed
    }

    private func basename(_ p: String) -> String {
        let trimmed = p.hasSuffix("/") ? String(p.dropLast()) : p
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return trimmed
    }

    // MARK: - Pane area
    @ViewBuilder
    private var paneArea: some View {
        // Only the active tab is mounted. We tried keeping inactive panes
        // alive at opacity 0 (MRU style for instant tab flips), but
        // SwiftTerm's `TerminalView` is itself a `UIScrollView`, and
        // SwiftUI's hit-testing didn't fully insulate the inactive
        // scroll views' pan gestures from the active one — typing into
        // the active terminal worked, but two-finger scrollback didn't.
        // Single-pane is simpler and SwiftTerm's scrollback replays
        // instantly from MotifClient's per-PTY ring buffer on remount.
        // The cost: PreviewPane edit buffers don't survive a tab switch
        // — acceptable for v1; lift edit state into MotifClient when it
        // becomes a problem.
        if let active = activeTab {
            paneFor(active)
                .id(active.viewID)
                .background(Color.black)
        }
    }

    @ViewBuilder
    private func paneFor(_ tab: SessionTab) -> some View {
        switch tab {
        case .pty(_, let ptyID):
            if let info = motif.ptys.first(where: { $0.id == ptyID }) {
                PtyTerminal(
                    ptyID: ptyID,
                    initialCols: info.cols,
                    initialRows: info.rows,
                    client: motif
                )
            }
        case .preview(_, let path):
            PreviewPane(path: path)
        case .diff(_, let staged, let path):
            DiffTabPane(name: name, staged: staged, path: path, cwd: activeCwd)
        case .image(_, let path):
            ImageTabPane(path: path)
        case .unknown(_, let kind):
            VStack(spacing: 8) {
                Image(systemName: "questionmark.square").font(.largeTitle)
                Text("Unsupported view kind: \(kind)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func spawnPty() async {
        do {
            // Server auto-opens and activates a view for the new PTY,
            // which fans out through `view.opened` + `view.active_changed`
            // → activeTab updates without us touching state here.
            _ = try await motif.createPty()
        } catch {
            self.error = "pty.create: \(error)"
        }
    }
}

/// Server-mirrored diff tab. Loads `git.diff` lazily and re-loads when
/// `motif.gitChangeTick` bumps. Heavy navigation (file picker, list/tree
/// switcher) lives in the dedicated `GitDiffPanel` route — this pane is
/// the inline read-only flavor that comes for free when web/another
/// client opens a diff view.
private struct DiffTabPane: View {
    @Environment(MotifClient.self) private var motif
    let name: String
    let staged: Bool
    let path: String?
    let cwd: String?

    @State private var patch: String = ""
    @State private var loading: Bool = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(staged ? "Staged" : "Working tree")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path { Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.footnote)
                }
            }
            .padding(8)
            Divider()
            if loading && patch.isEmpty {
                ProgressView().padding()
                Spacer()
            } else if let err = loadError {
                Text(err).foregroundStyle(.red).padding()
                Spacer()
            } else if patch.isEmpty {
                Text("No changes").foregroundStyle(.secondary).padding()
                Spacer()
            } else {
                ScrollView { Text(patch).font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                }
            }
        }
        .foregroundStyle(.white)
        .background(Color.black)
        .task { await load() }
        .onChange(of: motif.gitChangeTick) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            patch = try await motif.gitDiff(path: path, staged: staged, cwd: cwd)
        } catch {
            loadError = "git.diff: \(error)"
        }
    }
}

/// Lightweight image viewer. Decodes via `fs.read` (so it works without
/// blob plumbing) and falls back to a placeholder if the image is too
/// big or `fs.read` returns truncated bytes. Real "open the full
/// version" lands when blob transfer is wired up.
private struct ImageTabPane: View {
    @Environment(MotifClient.self) private var motif
    let path: String

    @State private var image: UIImage?
    @State private var loadError: String?
    @State private var truncated: Bool = false
    @State private var loading: Bool = true

    var body: some View {
        VStack(spacing: 8) {
            if loading && image == nil {
                ProgressView()
            } else if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                }
                if truncated {
                    Text("Image was truncated by fs.read; preview may be incomplete.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else if let err = loadError {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .foregroundStyle(.white)
        .background(Color.black)
        .task { await load() }
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let r = try await motif.fsRead(path: path)
            guard r.binary, let data = Data(base64Encoded: r.content_b64) else {
                loadError = "Not an image (\(r.mime ?? "unknown"))"
                return
            }
            guard let ui = UIImage(data: data) else {
                loadError = "Failed to decode image"
                return
            }
            image = ui
            truncated = r.truncated
        } catch {
            loadError = "fs.read: \(error)"
        }
    }
}
