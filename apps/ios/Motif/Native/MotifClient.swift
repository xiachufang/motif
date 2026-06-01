import Foundation
import Observation
import OSLog
import TalkerCommonLogging

/// High-level client around RpcClient that owns the active session +
/// PTY list and surfaces protocol events as observable state.
///
/// Lifecycle:
///   1. `connect(server:tailscale:)` opens a WebSocket directly to motifd
///      over the tsnet SOCKS5 proxy. No local 127.0.0.1 hop.
///   2. `attach(sessionName:)` joins a session and seeds the PTY/view
///      lists from the attach response.
///   3. UI subscribes to per-PTY output via `outputs(for:)`.
///
/// The implementation is split by domain across `MotifClient+Connection`,
/// `+Sessions`, `+PTY`, `+Views`, `+FS`, and `+Events`. Because Swift
/// extensions in other files can't see `private` members, the stored state
/// below is `internal` (and observable fields use plain `var` rather than
/// `private(set)`). By convention only `MotifClient` mutates this state — the
/// SwiftUI views that observe it treat it as read-only.
/// A server-side notification surfaced on the live channel (Claude Code hook).
/// `id` lets a banner view animate distinct notifications.
struct MotifNotification: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var body: String
    var sessionName: String?
}

@MainActor
@Observable
final class MotifClient {
    let log = Logger(subsystem: "io.allsunday.motif", category: "MotifClient")
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case attached(session: String)
        case failed(message: String)
    }

    var state: State = .disconnected
    var sessions: [MotifProto.SessionInfo] = []
    var ptys: [MotifProto.PtyInfo] = []
    var views: [MotifProto.ViewInfo] = []
    var activeViewID: String?
    /// True while the app scene is `.active`. Gates PTY primary (re)claims so
    /// a backgrounded client never steals primary from whoever is actually
    /// using the session. Updated by `ContentView`'s scenePhase observer.
    var isForeground = true
    /// Highest seq we've observed on the current WS — across every event
    /// kind, not just pty.output (server allocates one monotonic counter
    /// per session). Reset on attach to whatever the server returns in
    /// the attach response; bumped by handleEvent on every notification
    /// via `SeqPeek`. Snapshotted into `resumeSeqs` when the WS dies so a
    /// follow-up attach can ask the server for the diff.
    var lastSeq: UInt64 = 0
    /// Per-session resume markers, populated when the WS dies under us
    /// (`handleConnectionLost`). On a subsequent `attach(sessionName:)`,
    /// we hand the saved seq to the server as `last_seq` so it replays
    /// only events newer than that instead of the full ring. Cleared on
    /// successful attach, voluntary detach, destroy, and disconnect.
    /// Note: the terminal view gets torn down on conn loss, so resume
    /// saves bandwidth on the wire but doesn't preserve the rendered
    /// scrollback in the terminal view — that requires keeping the
    /// terminal view alive across reconnects, which is a separate change.
    var resumeSeqs: [String: UInt64] = [:]
    /// Session the user is currently *intending* to be attached to. Set
    /// by `attach()`, cleared by `detach()`/`disconnect()`/`destroy()`,
    /// and — critically — NOT cleared by `handleConnectionLost`. After a
    /// successful reconnect, `connect()` reads this to drive a transparent
    /// auto-reattach so the user lands back in their terminal instead of
    /// the session picker.
    var intendedSession: String?
    /// Terminal palette this client's Ghostty surface actually renders, as the
    /// rgb portion of an OSC 10/11 reply (e.g. `"d0d0/d0d0/d0d0"`). Sent on
    /// `session.attach` and re-pushed via `session.set_palette` whenever the
    /// user changes the terminal theme, so OSC 10/11 queries from PTY programs
    /// match what the user sees. Seeded at launch by `AppState`.
    var termFg: String?
    var termBg: String?
    /// This device's own resolved light/dark theme ("light"/"dark"), sent
    /// alongside the palette to assert it as the session theme when this
    /// client is driving.
    var termTheme: String?

    /// Session-wide effective theme broadcast by the server (set by whichever
    /// client is driving). When non-nil the whole UI renders in this theme so
    /// every client looks identical and PTY output colours match the
    /// background. `nil` → fall back to this device's own preference.
    var sessionTheme: String?
    /// Most recent server-side notification (Claude Code hook), for the
    /// in-app/live channel. A banner view can observe this; cleared by the
    /// consumer. Background delivery when the app is closed is handled out of
    /// band via APNs (see PushManager).
    var latestNotification: MotifNotification?
    /// Other clients attached to the same session. Seeded from
    /// `session.attach` and updated by `client.joined` / `client.left`.
    /// Excludes our own client_id (the server's attach response already
    /// returns just the *other* peers).
    var clients: [MotifProto.ClientInfo] = []
    /// Per-PTY currently-running command text (shell-integration marker from
    /// `pty.command_started`). Cleared on `pty.command_finished` or PTY
    /// exit. Empty/missing => the PTY is at a shell prompt or the shell
    /// never bootstrapped shell-integration. Used for tab labels.
    var runningCommand: [String: String] = [:]
    /// Detected shell per PTY, set by `pty.shell_bootstrapped` (or
    /// `.unknown` after the 5s timeout). Useful for tab badges /
    /// shell-aware affordances.
    var shellKind: [String: MotifProto.ShellKind] = [:]
    /// Latest `pty.shell_context` snapshot per PTY (branch / venv /
    /// node version / etc.). Refreshed on every precmd hook.
    var shellContext: [String: MotifProto.ShellContext] = [:]
    /// Bumped on every `tree.changed` notification. Views that cache
    /// fs.tree results (e.g. FileTreePanel) observe this to invalidate.
    /// Using a counter rather than the path list keeps the API minimal —
    /// observers refetch whichever cached subtrees they hold.
    var treeChangeTick: UInt64 = 0
    /// Same pattern as `treeChangeTick`, but for `git.changed` —
    /// GitDiffPanel / GitStatus observers re-run their RPCs when this
    /// flips.
    var gitChangeTick: UInt64 = 0

    /// Per-PTY byte cursors snapshotted from the dying RpcClient on an
    /// involuntary drop, seeded into the successor on reconnect so the
    /// `/pty/<id>` substream resumes from where we left off (no full-ring
    /// double-print into the surviving terminal surface). One-shot: cleared
    /// after seeding. See `handleConnectionLost` / `connect`.
    var carriedPtyCursors: [String: UInt64] = [:]

    /// True while the live transport is up. UI uses this to gate input and
    /// to choose server-authoritative vs local-only view switching.
    var isLive: Bool { rpc != nil }

    /// View the user switched to *locally* while offline (see
    /// `selectViewLocally`). On reconnect we push it to the server so their
    /// last viewing choice wins over the server's stale `active_view`,
    /// instead of yanking focus back. Cleared after reconcile / detach.
    var pendingLocalViewID: String?

    var rpc: RpcClient?
    var eventTask: Task<Void, Never>?
    /// Strong reference so the URLSession delegate stays alive for the
    /// lifetime of the connection.
    var wsDelegate: WSLogDelegate?

    /// Per-PTY output channel. This is only a live fan-out from the
    /// currently subscribed `/pty/<id>` stream to whichever terminal runtime
    /// is active. History lives on motifd; inactive tabs keep their Ghostty
    /// surface and catch up from the server when they become active again.
    final class PtyChannel {
        var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]
        var finished: Bool = false
    }
    var ptyChannels: [String: PtyChannel] = [:]
}
