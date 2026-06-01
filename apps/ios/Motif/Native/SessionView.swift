import SwiftUI
import UIKit
import OSLog
import TalkerCommonRouter
import TalkerMacro

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
/// Addressable as `/session` via CmRouter — `@Routable("/session")` on the
/// designated init synthesizes `path`, `route(name:)`, and `init?(_:)`.
///
/// Implementation is split across `SessionView+Tabs`, `SessionView+Panes`,
/// and `SessionView+Appearance`; members those files touch are `internal`
/// rather than `private` (Swift `private` is file-scoped).
struct SessionView: View {
    // `motif`, `appState`, `systemColorScheme`, `error`, and `showingTree` are
    // `internal` (not `private`) because the `SessionView+Tabs`/`+Panes`/
    // `+Appearance` extension files reach them — Swift `private` is file-scoped.
    @Environment(MotifClient.self) var motif
    @Environment(CmRouter.self) private var router
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var systemColorScheme
    let name: String
    @State var error: String?
    @State var showingTree: Bool = false
    @State private var showingTermSettings: Bool = false
    /// Name of the session a switch is in flight to, or nil. Gates the
    /// session menu so a second tap can't fire a second `attach` mid-switch.
    @State private var switching: String?
    /// How far to slide the terminal up so its bottom stays visible above the
    /// keyboard. The terminal *ignores* the keyboard safe area so its grid
    /// (rows/cols) never changes when the keyboard shows — this manual offset
    /// reveals the bottom of the fixed grid + the composer, clipping the top
    /// off-screen. Pinning the grid is the whole point: a keyboard-driven
    /// resize would SIGWINCH the PTY and force the remote TUI (e.g. Claude)
    /// to re-layout on every keyboard toggle.
    @State private var keyboardOverlap: CGFloat = 0
    /// Actual upward slide applied to the sliding unit. Derived from
    /// `keyboardOverlap` but reduced by the blank space below the terminal
    /// cursor, so a near-empty terminal (prompt at the top) doesn't get its
    /// content clipped off the top when the keyboard pushes it up. See
    /// `recomputeLift()`.
    @State private var effectiveLift: CGFloat = 0

    /// Breathing room kept between the cursor and the keyboard/input bar so the
    /// cursor never sits flush against them.
    private static let cursorKeyboardGap: CGFloat = 16

    private static let kbLog = Logger(subsystem: "io.allsunday.motif", category: "Keyboard")

    /// The key window's bottom safe-area inset (home-indicator height). Read
    /// from the window so it reflects the true device inset regardless of how
    /// nested SwiftUI safe-area handling reports it.
    private static var windowBottomInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        return window?.safeAreaInsets.bottom ?? 0
    }

    /// Recompute `effectiveLift` from the current keyboard overlap and the
    /// active terminal's cursor position. We lift the sliding unit by only as
    /// much as needed to keep the cursor clear of the keyboard (plus a small
    /// gap): when there's lots of blank terminal below the cursor (fresh
    /// shell, prompt near the top) the keyboard simply covers that blank space
    /// and we lift little or nothing — which avoids clipping the prompt off the
    /// top. As output fills the screen the cursor nears the bottom, `blankBelow`
    /// shrinks, and the lift grows back toward the full keyboard height.
    private func recomputeLift() {
        guard keyboardOverlap > 0 else { effectiveLift = 0; return }
        let blankBelow = (appState.terminals.view(for: activeTerminalPtyID) as? MotifTerminalView)?
            .cursorDistanceFromBottom() ?? 0
        // Cap at `keyboardOverlap`: the pane never needs to rise higher than the
        // keyboard, and going higher would open a gap between the terminal's
        // bottom and the input bar (which is pinned at the keyboard's top edge).
        effectiveLift = min(keyboardOverlap, max(0, keyboardOverlap - blankBelow + Self.cursorKeyboardGap))
    }

    /// Project the server's view list into our heterogeneous tab enum.
    /// Order matches `motif.views`, which the server keeps consistent
    /// across clients via `view.opened` / `view.moved` events.
    var allTabs: [SessionTab] {
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
    var activeTab: SessionTab? {
        guard let id = motif.activeViewID else { return nil }
        return allTabs.first(where: { $0.viewID == id })
    }

    /// cwd of the currently active PTY — used as the file-tree root and
    /// the cwd hint for git.diff so both follow the same shell as the
    /// user navigates with `cd`. When the active tab isn't a PTY (it's a
    /// preview / diff / image), fall back to any PTY with a known cwd
    /// so the file tree and diff button still have a useful default.
    var activeCwd: String? {
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

    /// Program name running in the active PTY (e.g. "claude"), if any —
    /// passed to the quick-command manager as a one-tap "customize" shortcut.
    private var runningProgram: String? {
        guard let id = activePtyID else { return nil }
        return QuickCommandStore.programKey(motif.runningCommand[id])
    }

    /// PTY id that should receive the real-time `/pty/<id>` subscription.
    /// Unlike `activePtyID`, this does not fall back while preview/diff/image
    /// tabs are active; hidden terminals catch up from motifd when selected.
    private var activeTerminalPtyID: String? {
        if case .pty(_, let id) = activeTab { return id }
        return nil
    }

    private var livePtyIDs: Set<String> {
        Set(motif.ptys.map(\.id))
    }

    var preferredPtySize: (cols: UInt16, rows: UInt16) {
        if case .pty(_, let ptyID) = activeTab,
           let pty = motif.ptys.first(where: { $0.id == ptyID }),
           pty.cols > 0,
           pty.rows > 0
        {
            return (pty.cols, pty.rows)
        }
        if let pty = motif.ptys.first(where: { ($0.alive ?? true) && $0.cols > 0 && $0.rows > 0 }) {
            return (pty.cols, pty.rows)
        }
        // No existing PTY to borrow a size from — use the last settled grid
        // (persisted across launches) so the new PTY is created at the device's
        // real size and the server never has to column-shrink it. Only an
        // absolute first-ever launch (empty cache) falls back to 80×24.
        if let g = appState.terminals.lastSettledGrid {
            return g
        }
        return (80, 24)
    }

    @Routable("/session")
    init(name: String) {
        self.name = name
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            // Sliding unit: the whole screen opts out of SwiftUI's keyboard
            // avoidance (`.ignoresSafeArea(.keyboard)` below) — that's what
            // keeps the terminal's *frame* (and therefore the PTY grid) fixed,
            // since avoidance is otherwise consumed at this VStack level and
            // shrinks the pane no matter what a nested child ignores. We slide
            // manually with `.offset`, a render-only translation that never
            // changes the frame → no grid recompute → no SIGWINCH → no remote
            // re-layout.
            //
            // The terminal and the input bar lift by DIFFERENT amounts:
            //  - The VStack (terminal) lifts by `effectiveLift` — the
            //    cursor-aware amount (≤ keyboardOverlap), so a near-empty
            //    terminal isn't clipped off the top. Its top rows clip under
            //    the tab bar once content is tall enough to need a full lift.
            //  - The input bar lifts by the *full* `keyboardOverlap` via an
            //    extra `-(keyboardOverlap - effectiveLift)` offset, so it always
            //    sits flush on top of the keyboard regardless of cursor
            //    position. When the pane lifts less than the bar, the (opaque)
            //    bar simply overlaps the terminal's blank/lower bottom rows.
            ZStack(alignment: .bottom) {
                // Fill the area below the input bar with the bar's own
                // `.background` colour (not the parent `MotifTheme.background`),
                // so lifting the bar above the keyboard — or a transient gap
                // during the keyboard show/hide animation — never exposes a
                // colour seam beneath it. It sits behind the terminal and the
                // bar (both opaque), so it only shows through that bottom strip.
                Rectangle()
                    .fill(.background)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 0) {
                    paneArea
                    if let error {
                        Text(error)
                            .font(MotifTheme.Typography.caption)
                            .foregroundStyle(MotifTheme.danger)
                            .padding(MotifTheme.Spacing.sm)
                    }
                    BottomInputBar(activePtyID: activePtyID)
                        // Top up the bar's lift to the full keyboard overlap so it
                        // never hides behind the keyboard. `effectiveLift` is capped
                        // at `keyboardOverlap`, so this delta is always ≥ 0.
                        .offset(y: -(keyboardOverlap - effectiveLift))
                }
                .offset(y: -effectiveLift)
                .clipped()
                .animation(.easeOut(duration: 0.25), value: keyboardOverlap)
                .animation(.easeOut(duration: 0.25), value: effectiveLift)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(MotifTheme.background.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            // iPhone keyboards dock at the bottom, so the end-frame height is
            // its overlap with the window. The composer's `.safeAreaInset`
            // already clears the home indicator, so we slide only by the part
            // *above* that — subtracting the window's bottom inset. (Reading it
            // off the window, not a GeometryReader nested inside a safe-area-
            // respecting view, which reports 0 and over-slides by ~34pt.)
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let inset = Self.windowBottomInset
            keyboardOverlap = max(0, frame.height - inset)
            recomputeLift()
            Self.kbLog.notice("[kb] willChangeFrame kbHeight=\(String(format: "%.0f", frame.height), privacy: .public) bottomInset=\(String(format: "%.0f", inset), privacy: .public) -> overlap=\(String(format: "%.0f", self.keyboardOverlap), privacy: .public) lift=\(String(format: "%.0f", self.effectiveLift), privacy: .public)")
            // Don't snap-to-bottom on every keyboard appearance: the terminal
            // surface raises the keyboard too (it's first responder when
            // focused), and focusing the terminal must NOT jump the viewport.
            // Only focusing the composer scrolls to bottom — handled in
            // BottomInputBar's `onChange(of: focused)`.
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            Self.kbLog.notice("[kb] willHide -> overlap=0")
            keyboardOverlap = 0
            effectiveLift = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .motifTerminalDidRender)) { note in
            // Output moved the cursor while the keyboard is up — re-evaluate the
            // lift so a filling terminal keeps the prompt clear of the keyboard.
            // No animation: the offset should track output without a visible
            // creeping slide.
            guard keyboardOverlap > 0,
                  note.userInfo?["ptyID"] as? String == activeTerminalPtyID else { return }
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { recomputeLift() }
        }
        .task {
            applyAppearance()
            // Populate the session menu (and keep it fresh on re-entry) so the
            // switcher shows every session, not just whatever the list view
            // last cached before we attached.
            await motif.refreshSessions()
            appState.terminals.syncRuntimes(
                client: motif,
                livePtyIDs: livePtyIDs,
                activePtyID: activeTerminalPtyID,
                keepInactiveLive: appState.terminalSettings.keepInactiveTabsLive
            )
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
        .onChange(of: livePtyIDs) { _, ids in
            appState.terminals.syncRuntimes(
                client: motif,
                livePtyIDs: ids,
                activePtyID: activeTerminalPtyID,
                keepInactiveLive: appState.terminalSettings.keepInactiveTabsLive
            )
        }
        .onChange(of: activeTerminalPtyID) { _, ptyID in
            appState.terminals.syncRuntimes(
                client: motif,
                livePtyIDs: livePtyIDs,
                activePtyID: ptyID,
                keepInactiveLive: appState.terminalSettings.keepInactiveTabsLive
            )
        }
        .onChange(of: appState.terminalSettings.keepInactiveTabsLive) { _, keep in
            // Toggling the policy live: opens background streams (and their
            // surfaces) when turned on, tears them down when turned off.
            appState.terminals.syncRuntimes(
                client: motif,
                livePtyIDs: livePtyIDs,
                activePtyID: activeTerminalPtyID,
                keepInactiveLive: keep
            )
        }
        .onChange(of: motif.state) { _, newState in
            // Transparent reconnect: the auto-reattach in MotifClient.connect
            // lands us back on `.attached` with the session view preserved.
            // Re-open every streaming PTY's substream on the fresh connection so
            // live output resumes into the surviving terminal surfaces.
            if case .attached = newState {
                appState.terminals.reactivateStreaming()
            }
        }
        .onChange(of: appState.terminalSettings.fontSize) { _, _ in applyAppearance() }
        .onChange(of: appState.terminalSettings.theme) { _, _ in pushLocalThemeAsDriver(); applyAppearance() }
        .onChange(of: systemColorScheme) { _, _ in pushLocalThemeAsDriver(); applyAppearance() }
        // Adopt the session-wide theme broadcast by the driving client.
        .onChange(of: motif.sessionTheme) { _, _ in applyAppearance() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Post-attach route, so the chip is always "active" — a drop
                // here shows the reconnect status in the nav bar instead of
                // taking over the terminal.
                ConnectionStatusChip(active: true)
            }
            ToolbarItem(placement: .topBarLeading) {
                sessionMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingTermSettings = true
                } label: {
                    Image(systemName: "gearshape")
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
                    .foregroundStyle(MotifTheme.textSecondary)
                    .padding()
            }
        }
        .sheet(isPresented: $showingTermSettings) {
            TerminalSettingsSheet().environment(appState)
        }
        .navigationBarBackButtonHidden(true)
    }

    /// Top-left control. Tap to drop a menu offering "Close session" (leave
    /// the current session and return to the picker) plus the full session
    /// list — tapping another session switches to it in place. The session
    /// we're already on is shown with a checkmark and disabled.
    private var sessionMenu: some View {
        Menu {
            Button(role: .destructive) {
                router.pop()
            } label: {
                Label("Close session", systemImage: "xmark")
            }
            if !motif.sessions.isEmpty {
                Section("Sessions") {
                    ForEach(motif.sessions) { session in
                        let isCurrent = session.name == name
                        Button {
                            switchTo(session.name)
                        } label: {
                            if isCurrent {
                                Label(session.name, systemImage: "checkmark")
                            } else {
                                Text(session.name)
                            }
                        }
                        .disabled(isCurrent || switching != nil)
                    }
                }
            }
        } label: {
            Image(systemName: "xmark")
        }
        .disabled(switching != nil)
    }

    /// Switch to another session in place: attach to it, then `replace` the
    /// current `/session` route with the target's. The router's `afterPop`
    /// won't detach us mid-switch — see `MotifClient.detachIfCurrent`.
    private func switchTo(_ target: String) {
        guard target != name, switching == nil else { return }
        switching = target
        Task {
            defer { switching = nil }
            do {
                try await motif.attach(sessionName: target)
                let (path, query) = SessionView.route(name: target)
                router.replace(CmRouterPath(path, query))
            } catch {
                self.error = "switch to \(target): \(error)"
            }
        }
    }
}
