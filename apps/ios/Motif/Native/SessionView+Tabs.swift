import SwiftUI
import TalkerCommonRouter

// Tab bar + tab management for `SessionView`. Entry points reached from
// `SessionView.body` (`tabBar`, `openPreview`) are `internal`; the rest stay
// file-private.
extension SessionView {
    // MARK: - Tab management

    /// File tree's "open" → server-side preview view. The resulting
    /// `view.opened` + `view.active_changed` events fan out and flip
    /// our derived activeTab to match.
    func openPreview(_ path: String) {
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
        // Online: server-authoritative switch (mirrors across clients, claims
        // PTY primary). Offline: switch locally so the user can still read
        // other terminals' retained scrollback; reconnect reconciles.
        if motif.isLive {
            Task { await motif.activateView(viewID: tab.viewID) }
        } else {
            motif.selectViewLocally(viewID: tab.viewID)
        }
    }

    // MARK: - Tab bar

    var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MotifTheme.Spacing.sm) {
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
            .padding(MotifTheme.Spacing.sm)
        }
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

        HStack(spacing: MotifTheme.Spacing.xs) {
            Button {
                activate(tab)
            } label: {
                HStack(spacing: MotifTheme.Spacing.xs) {
                    Image(systemName: tabIcon(tab))
                    Text(tabLabel(tab, ordinal: ordinal))
                        .font(MotifTheme.Typography.caption.monospaced())
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
                        .font(MotifTheme.Typography.caption2)
                        .foregroundStyle(MotifTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? MotifTheme.accent.opacity(0.18) : MotifTheme.Fill.subtle, in: Capsule())
        // Active tab promotes label + icon to accent; close button overrides
        // back to textSecondary explicitly so it stays muted regardless.
        .foregroundStyle(isActive ? MotifTheme.accent : MotifTheme.textPrimary)
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
}
