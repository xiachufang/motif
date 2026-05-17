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
    @State private var attaching: String?
    @State private var creatingSheet: Bool = false
    /// Name of the session the user has asked to destroy. Drives the
    /// confirmation alert; non-nil means "alert is visible". Cleared in
    /// both the OK and Cancel branches.
    @State private var destroyTarget: String?

    var body: some View {
        // Always render a List so `.refreshable` is available across
        // every state (loading, empty, populated). The variants are
        // expressed as Section contents inside.
        List {
            if let error {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            if motif.sessions.isEmpty && loading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else if motif.sessions.isEmpty {
                Section {
                    emptyStateRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(motif.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refresh() }
        .task { await refresh() }
        .onChange(of: motif.state) { _, newState in
            // After a transparent reconnect (failed → connecting → connected)
            // the existing .task fired only on first appear, so the list
            // would keep showing whatever sessions were cached pre-drop.
            // Re-fetch whenever we land back on .connected.
            if case .connected = newState {
                Task { await refresh() }
            }
        }
        .toolbar {
            // Leading slot — NativeRoot's `rootToolbar` already owns the
            // `.principal` (server picker) and `.topBarTrailing` (info)
            // placements, so put the create CTA on the opposite side
            // instead of fighting for trailing space.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    creatingSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(attaching != nil)
            }
        }
        .sheet(isPresented: $creatingSheet) {
            CreateSessionSheet { name, workdir in
                creatingSheet = false
                await createAndAttach(name: name, workdir: workdir)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
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

    // MARK: - Rows

    @ViewBuilder
    private func sessionRow(_ session: MotifProto.SessionInfo) -> some View {
        Button {
            Task { await attach(session.name) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let wd = session.workdir, !wd.isEmpty {
                        Label {
                            Text(wd)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "folder")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        if let count = session.client_count, count > 0 {
                            Label("\(count) attached", systemImage: "person.2.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                        if let ms = session.created_at, ms > 0 {
                            Text(relativeTime(unixMs: ms))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 8)
                if attaching == session.name {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
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

    // MARK: - Empty state

    /// Hosted inside a List row so `.refreshable` still fires when the
    /// user pulls down from this state. The error string also lives in
    /// its own list section above, but we mirror it here too so users
    /// reading the empty-state copy don't miss it.
    private var emptyStateRow: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No sessions yet")
                    .font(.headline)
                Text("Create one to attach a workspace on this server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                creatingSheet = true
            } label: {
                Label("Create session", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

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

    private func createAndAttach(name: String, workdir: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workdir = workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !workdir.isEmpty else { return }
        attaching = name
        defer { attaching = nil }
        do {
            _ = try await motif.createSession(name: name, workdir: workdir)
            try await motif.attach(sessionName: name)
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

    /// "2h ago", "Just now", etc. Lazy formatter — kept around so we
    /// don't re-allocate one per row repaint when the list scrolls.
    private func relativeTime(unixMs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000)
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// Modal create-session form. Lifted out of the list so the parent screen
/// stays scroll-only — entering "name + workdir" used to push the list
/// down out of view on smaller iPhones whenever the keyboard came up.
private struct CreateSessionSheet: View {
    let onCreate: (_ name: String, _ workdir: String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var workdir: String = "~"
    @State private var submitting: Bool = false
    @FocusState private var focused: Field?
    private enum Field { case name, workdir }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .name)
                        .onSubmit { focused = .workdir }
                    TextField("Working directory", text: $workdir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($focused, equals: .workdir)
                        .onSubmit { if isValid { submit() } }
                } footer: {
                    Text("Working directory must exist on the server. ~ expands to the motifd user's home.")
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create") { submit() }
                            .disabled(!isValid)
                    }
                }
            }
            .onAppear { focused = .name }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !workdir.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        submitting = true
        Task {
            await onCreate(name, workdir)
            submitting = false
        }
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
    @State private var quitConfirm: Bool = false
    /// FR state — split because SwiftUI's `@FocusState` can only track
    /// values that some SwiftUI view binds via `.focused(_:equals:)`, and
    /// UITerminalView (UIKit) can't carry that modifier. So:
    ///   - `bottomBarFocused` (`@FocusState`) drives the composer
    ///     TextField, the only SwiftUI-side keyboard owner.
    ///   - `termFocused` (`@State`) drives UITerminalView FR through
    ///     GhosttyPtyTerminal's `updateUIView` (which calls
    ///     `becomeFirstResponder` / `resignFirstResponder` directly).
    /// The two are kept mutually exclusive by `.onChange` watchers below
    /// — only one keyboard owner at a time. Trying to fold both into a
    /// single `@FocusState<EnumCase?>` caused SwiftUI to silently reset
    /// the value back to `nil` when no SwiftUI view bound the
    /// `.terminal` case, which flickered the keyboard.
    @FocusState private var bottomBarFocused: Bool
    @State private var termFocused: Bool = false
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

    /// PTY id the BottomInputBar should write to. Active tab's PTY when
    /// the user is in a terminal; falls back to the first live PTY when
    /// viewing a preview / diff / image so quick commands still work.
    private var activePtyID: String? {
        if case .pty(_, let id) = activeTab { return id }
        return motif.ptys.first(where: { $0.alive ?? true })?.id
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
                .padding(.bottom)
            BottomInputBar(activePtyID: activePtyID, focused: $bottomBarFocused)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .background(Color.black)
        .onChange(of: bottomBarFocused) { _, isFocused in
            // Composer pulled FR (user tapped the TextField, quick-tap
            // inserted text, ASR start, etc.). Drop the terminal so we
            // never advertise two keyboard owners.
            if isFocused { termFocused = false }
        }
        .onChange(of: termFocused) { _, isFocused in
            // Terminal pulled FR (tap GR). Drop the composer; UIKit will
            // hand the keyboard off to UITerminalView without a dismiss.
            if isFocused { bottomBarFocused = false }
        }
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
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    quitConfirm = true
                } label: {
                    Image(systemName: "xmark")
                }
                .confirmationDialog("Quit", isPresented: $quitConfirm) {
                    Button("Quit") {
                        router.pop()
                    }
                } message: {
                    Text("Are you sure to quit?")
                }
            }
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
        .navigationBarBackButtonHidden(true)
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
        // alive at opacity 0 (MRU style for instant tab flips), but the
        // terminal view is itself a scroll view, and SwiftUI's hit-testing
        // didn't fully insulate the inactive scroll views' pan gestures
        // from the active one — typing into the active terminal worked,
        // but two-finger scrollback didn't. Single-pane is simpler and
        // the terminal scrollback replays instantly from MotifClient's
        // per-PTY ring buffer on remount. The cost: PreviewPane edit
        // buffers don't survive a tab switch — acceptable for v1; lift
        // edit state into MotifClient when it becomes a problem.
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
                GhosttyPtyTerminal(
                    ptyID: ptyID,
                    initialCols: info.cols,
                    initialRows: info.rows,
                    client: motif,
                    isFocused: termFocused,
                    setFocused: { termFocused = $0 }
                )
                .id(ptyID)
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
