import SwiftUI

// Active-pane rendering for `SessionView`. `paneArea` and `spawnPty` are
// reached from `SessionView.body`/tab bar so they are `internal`.
extension SessionView {
    // MARK: - Pane area
    @ViewBuilder
    var paneArea: some View {
        // Only the active tab is mounted. We tried keeping inactive panes
        // alive at opacity 0 (MRU style for instant tab flips), but the
        // terminal view is itself a scroll view, and SwiftUI's hit-testing
        // didn't fully insulate the inactive scroll views' pan gestures
        // from the active one — typing into the active terminal worked,
        // but two-finger scrollback didn't. Single-pane is simpler: each
        // PTY runtime stays subscribed and keeps its Ghostty surface/state
        // alive, while SwiftUI only mounts the currently visible UIView.
        // PreviewPane edit buffers still do not survive a tab switch —
        // acceptable for v1; lift edit state into MotifClient when it
        // becomes a problem.
        if let active = activeTab {
            paneFor(active)
                .id(active.viewID)
                .background(MotifTheme.background)
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
                    terminals: appState.terminals
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
            VStack(spacing: MotifTheme.Spacing.sm) {
                Image(systemName: "questionmark.square").font(MotifTheme.Typography.largeTitle)
                Text("Unsupported view kind: \(kind)")
                    .foregroundStyle(MotifTheme.textSecondary)
            }
        }
    }

    func spawnPty() async {
        do {
            // Server auto-opens and activates a view for the new PTY,
            // which fans out through `view.opened` + `view.active_changed`
            // → activeTab updates without us touching state here.
            let size = preferredPtySize
            _ = try await motif.createPty(cols: size.cols, rows: size.rows)
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
                    .font(MotifTheme.Typography.caption)
                    .foregroundStyle(MotifTheme.textSecondary)
                if let path { Text(path).font(MotifTheme.Typography.caption.monospaced()).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(MotifTheme.Typography.footnote)
                }
            }
            .padding(MotifTheme.Spacing.sm)
            Divider()
            if loading && patch.isEmpty {
                ProgressView().padding()
                Spacer()
            } else if let err = loadError {
                Text(err).foregroundStyle(MotifTheme.danger).padding()
                Spacer()
            } else if patch.isEmpty {
                Text("No changes").foregroundStyle(MotifTheme.textSecondary).padding()
                Spacer()
            } else {
                ScrollView { Text(patch).font(MotifTheme.Typography.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(MotifTheme.Spacing.sm)
                }
            }
        }
        .foregroundStyle(MotifTheme.textPrimary)
        .background(MotifTheme.background)
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
        VStack(spacing: MotifTheme.Spacing.sm) {
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
                        .font(MotifTheme.Typography.caption2)
                        // Warning hue — separate from brand accent.
                        .foregroundStyle(.orange)
                }
            } else if let err = loadError {
                VStack(spacing: MotifTheme.Spacing.xs) {
                    Image(systemName: "photo.badge.exclamationmark").font(MotifTheme.Typography.largeTitle)
                    Text(err).font(MotifTheme.Typography.footnote).foregroundStyle(MotifTheme.danger)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .foregroundStyle(MotifTheme.textPrimary)
        .background(MotifTheme.background)
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
