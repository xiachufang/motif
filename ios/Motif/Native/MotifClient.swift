import Foundation
import Observation
import OSLog

/// High-level client around RpcClient that owns the active session +
/// PTY list and surfaces protocol events as observable state.
///
/// Lifecycle:
///   1. `connect(server:tailscale:)` opens a WebSocket directly to motifd
///      over the tsnet SOCKS5 proxy. No local 127.0.0.1 hop.
///   2. `attach(sessionName:)` joins a session and seeds the PTY/view
///      lists from the attach response.
///   3. UI subscribes to per-PTY output via `outputs(for:)`.
@MainActor
@Observable
final class MotifClient {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "MotifClient")
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case attached(session: String)
        case failed(message: String)
    }

    private(set) var state: State = .disconnected
    private(set) var sessions: [MotifProto.SessionInfo] = []
    private(set) var ptys: [MotifProto.PtyInfo] = []
    private(set) var views: [MotifProto.ViewInfo] = []
    private(set) var activeViewID: String?
    /// Highest seq we've observed on the current WS — across every event
    /// kind, not just pty.output (server allocates one monotonic counter
    /// per session). Reset on attach to whatever the server returns in
    /// the attach response; bumped by handleEvent on every notification
    /// via `SeqPeek`. Snapshotted into `resumeSeqs` when the WS dies so a
    /// follow-up attach can ask the server for the diff.
    private(set) var lastSeq: UInt64 = 0
    /// Per-session resume markers, populated when the WS dies under us
    /// (`handleConnectionLost`). On a subsequent `attach(sessionName:)`,
    /// we hand the saved seq to the server as `last_seq` so it replays
    /// only events newer than that instead of the full ring. Cleared on
    /// successful attach, voluntary detach, destroy, and disconnect.
    /// Note: SwiftTerm gets torn down on conn loss, so resume saves
    /// bandwidth on the wire but doesn't preserve the rendered scrollback
    /// in the terminal view — that requires keeping the SwiftTerm
    /// `TerminalView` alive across reconnects, which is a separate change.
    private var resumeSeqs: [String: UInt64] = [:]
    /// Session the user is currently *intending* to be attached to. Set
    /// by `attach()`, cleared by `detach()`/`disconnect()`/`destroy()`,
    /// and — critically — NOT cleared by `handleConnectionLost`. After a
    /// successful reconnect, `connect()` reads this to drive a transparent
    /// auto-reattach so the user lands back in their terminal instead of
    /// the session picker.
    private var intendedSession: String?
    /// Other clients attached to the same session. Seeded from
    /// `session.attach` and updated by `client.joined` / `client.left`.
    /// Excludes our own client_id (the server's attach response already
    /// returns just the *other* peers).
    private(set) var clients: [MotifProto.ClientInfo] = []
    /// Per-PTY currently-running command text (OSC 7770 from
    /// `pty.command_started`). Cleared on `pty.command_finished` or PTY
    /// exit. Empty/missing => the PTY is at a shell prompt or the shell
    /// never bootstrapped shell-integration. Used for tab labels.
    private(set) var runningCommand: [String: String] = [:]
    /// Detected shell per PTY, set by `pty.shell_bootstrapped` (or
    /// `.unknown` after the 5s timeout). Useful for tab badges /
    /// shell-aware affordances.
    private(set) var shellKind: [String: MotifProto.ShellKind] = [:]
    /// Latest `pty.shell_context` snapshot per PTY (branch / venv /
    /// node version / etc.). Refreshed on every precmd hook.
    private(set) var shellContext: [String: MotifProto.ShellContext] = [:]
    /// Bumped on every `tree.changed` notification. Views that cache
    /// fs.tree results (e.g. FileTreePanel) observe this to invalidate.
    /// Using a counter rather than the path list keeps the API minimal —
    /// observers refetch whichever cached subtrees they hold.
    private(set) var treeChangeTick: UInt64 = 0
    /// Same pattern as `treeChangeTick`, but for `git.changed` —
    /// GitDiffPanel / GitStatus observers re-run their RPCs when this
    /// flips.
    private(set) var gitChangeTick: UInt64 = 0

    private var rpc: RpcClient?
    private var eventTask: Task<Void, Never>?
    /// Strong reference so the URLSession delegate stays alive for the
    /// lifetime of the connection.
    private var wsDelegate: WSLogDelegate?

    /// Per-PTY output channel. Keeps a small ring buffer of the most
    /// recent bytes (so a tab switched away and back can replay scrollback
    /// into a fresh SwiftTerm) plus a set of live subscribers that all
    /// receive every new chunk. Survives `pty.exited` so a tab opened
    /// after the PTY died can still see the captured output.
    private final class PtyChannel {
        var buffer: [Data] = []
        var bufferBytes: Int = 0
        var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]
        var finished: Bool = false
    }
    private var ptyChannels: [String: PtyChannel] = [:]
    /// Per-PTY replay budget. SwiftTerm has its own scrollback once we
    /// feed it; this only needs to cover bytes that arrived while the
    /// terminal view didn't exist.
    private let maxBufferBytesPerPty = 512 * 1024

    func connect(server: MotifServer, tailscale: TailscaleManager) async {
        if case .connected = state { return }
        if case .attached = state { return }
        state = .connecting

        // Pick the URLSession config based on server kind. `.tailscale`
        // servers go through tsnet's HTTP CONNECT loopback so the WS
        // upgrade gets routed inside the tailnet; `.direct` servers use
        // a plain URLSession with no proxy. The Authorization header
        // (set below) carries the per-server Bearer token in both cases.
        // WSLogDelegate is attached so we can see the upgrade response
        // code, headers, and any close reasons.
        let urlSessionConfig: URLSessionConfiguration
        switch server.kind {
        case .tailscale:
            do {
                urlSessionConfig = try await tailscale.makeURLSessionConfiguration()
            } catch {
                log.error("tsnet not ready: \(String(describing: error), privacy: .public)")
                state = .failed(message: "tsnet not ready: \(error)")
                return
            }
        case .direct:
            urlSessionConfig = .default
        }
        let delegate = WSLogDelegate()
        self.wsDelegate = delegate
        let urlSession = URLSession(configuration: urlSessionConfig, delegate: delegate, delegateQueue: nil)

        // For `.tailscale` we rewrite MagicDNS names to peer IPs as a
        // safety net for build/config combos where DNS resolves locally.
        // For `.direct` we trust the host string as-typed.
        let resolvedHost: String
        switch server.kind {
        case .tailscale:
            resolvedHost = await tailscale.resolveTailnetHost(server.host) ?? server.host
            if resolvedHost != server.host {
                log.notice("resolved \(server.host, privacy: .public) -> \(resolvedHost, privacy: .public)")
            }
        case .direct:
            resolvedHost = server.host
        }

        // Negotiate the MessagePack codec — keeps PTY bytes off base64 and
        // saves the JSON envelope on every frame. motifd's /ws handler
        // accepts `?bin=1` to flip its codec; older clients without the
        // flag stay on JSON.
        guard let url = URL(string: "ws://\(resolvedHost):\(server.port)/ws?bin=1") else {
            log.error("bad server URL: \(resolvedHost, privacy: .public):\(server.port, privacy: .public)")
            state = .failed(message: "bad server URL: \(resolvedHost):\(server.port)")
            return
        }
        log.notice("motifd target=\(server.name, privacy: .public) host=\(server.host, privacy: .public) resolved=\(resolvedHost, privacy: .public) port=\(server.port, privacy: .public) tokenLen=\(server.token.count, privacy: .public)")
        FileLog.note("MotifClient", "connect target=\(server.name) host=\(server.host) resolved=\(resolvedHost) port=\(server.port) tokenLen=\(server.token.count)")

        // Pre-warm the magicsock path before we ask URLSession to open the
        // WS. `state=Running` only means controlplane is up — the first
        // data packet to a specific peer still pays NAT discovery / DERP
        // fallback, which on a cold start can exceed URLSession's request
        // timeout. A throwaway TCP dial through tailscale_dial provokes
        // that setup OUTSIDE of URLSession's timeout window, so the WS
        // upgrade lands on an already-hot path. Best-effort: if the dial
        // hangs or fails, the WS attempt is still tried (and now has a
        // 15s timeout instead of the URLSession default 60s).
        if case .tailscale = server.kind {
            await preWarmTsnetPath(host: resolvedHost, port: server.port, tailscale: tailscale)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        // Default URLSession request timeout is 60s — too long when the
        // tsnet path is wedged. Pair with NativeRoot's exponential backoff
        // so a stuck handshake fails fast and the retry loop picks up.
        request.timeoutInterval = 15

        let rpc = RpcClient(wireMode: .binary)
        do {
            try await rpc.connect(urlSession: urlSession, request: request, delegate: delegate)
        } catch {
            log.error("ws connect: \(String(describing: error), privacy: .public)")
            FileLog.note("MotifClient", "ws connect failed: \(error)")
            state = .failed(message: "ws connect: \(error)")
            return
        }
        self.rpc = rpc
        log.notice("connected to motifd as \(server.name, privacy: .public)")
        FileLog.note("MotifClient", "ws task resumed (state=connected)")
        eventTask = Task { [weak self] in
            guard let stream = self?.rpc?.events else { return }
            for await event in stream {
                self?.handleEvent(event)
            }
            // The events stream finishes when RpcClient's recvLoop hits
            // a transport error (or when we explicitly close). Either
            // way the WS is dead — flip back to .failed so the UI
            // surfaces the Retry button instead of leaving SessionList
            // hammering RPC calls into a dead socket.
            await self?.handleConnectionLost()
        }

        // Auto-rehydrate: if we were attached to a session before a WS
        // drop, transparently reattach now so the user lands back in
        // their terminal. Skip the transient `.connected` step (jump
        // straight from `.connecting` to `.attached`) so the UI overlay
        // shows "Connecting…" continuously across reconnect+reattach
        // rather than flashing a blank session picker mid-cycle.
        if let name = intendedSession {
            log.notice("auto re-attaching to \(name, privacy: .public)")
            FileLog.note("MotifClient", "auto re-attaching to \(name)")
            do {
                try await attach(sessionName: name)
            } catch {
                // Session was destroyed / renamed / otherwise gone. Stop
                // looping on the same failure; drop to `.connected` so the
                // user lands on the picker on their next interaction.
                log.error("auto re-attach \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                FileLog.note("MotifClient", "auto re-attach \(name) failed: \(error)")
                intendedSession = nil
                state = .connected
            }
        } else {
            state = .connected
        }
    }

    /// Best-effort TCP dial through tsnet to provoke the magicsock path
    /// setup before the WS upgrade. Races the dial against an 8s timeout
    /// so a wedged path doesn't stall the connect indefinitely — if it
    /// times out or errors, we still proceed to the WS attempt (which
    /// has its own 15s URLRequest timeout). The probe connection is
    /// closed immediately; we just want the side effect of building the
    /// peer route in libtailscale.
    private func preWarmTsnetPath(host: String, port: UInt16, tailscale: TailscaleManager) async {
        let start = Date()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let conn = try await tailscale.dial(host: host, port: port)
                    await conn.close()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8 * 1_000_000_000)
                    throw PreWarmTimeout()
                }
                _ = try await group.next()
                group.cancelAll()
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            log.notice("tsnet path pre-warmed to \(host, privacy: .public):\(port, privacy: .public) in \(ms, privacy: .public)ms")
            FileLog.note("MotifClient", "tsnet pre-warm ok \(host):\(port) (\(ms)ms)")
        } catch {
            // Don't fail the connect; the WS attempt will surface the real
            // error if the path really is broken.
            log.warning("tsnet pre-warm dial failed: \(String(describing: error), privacy: .public)")
            FileLog.note("MotifClient", "tsnet pre-warm failed: \(error)")
        }
    }

    private struct PreWarmTimeout: Error, CustomStringConvertible {
        var description: String { "pre-warm dial timed out" }
    }

    /// Called once the events stream finishes. If the user explicitly
    /// disconnect()ed we already cleaned up; only act when the WS died
    /// out from under us (state is .connecting/.connected/.attached).
    private func handleConnectionLost() async {
        switch state {
        case .disconnected, .failed:
            return
        case .connecting, .connected, .attached:
            break
        }
        // Snapshot the resume marker BEFORE clearing state — once we hit
        // `clearSessionState` lastSeq is no longer meaningful for any
        // particular session, and we still need the value to hand back
        // to the server on the next attach.
        if case .attached(let name) = state, lastSeq > 0 {
            resumeSeqs[name] = lastSeq
            log.notice("saved resume marker for \(name, privacy: .public) at seq=\(self.lastSeq, privacy: .public)")
        }
        log.notice("connection lost — resetting state")
        FileLog.note("MotifClient", "connection lost; resetting state")
        eventTask?.cancel()
        eventTask = nil
        if let rpc { await rpc.close() }
        rpc = nil
        clearSessionState()
        state = .failed(message: "connection lost")
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        if let rpc { await rpc.close() }
        rpc = nil
        clearSessionState()
        // Manual disconnect = "forget everything". Drop resume markers so a
        // subsequent attach starts from the full ring instead of a stale
        // seq from a different server/session. Also drop the auto-reattach
        // intent so the next connect lands on the picker.
        resumeSeqs.removeAll()
        intendedSession = nil
        lastSeq = 0
        state = .disconnected
    }

    /// Drop every per-session piece of state so a fresh attach (or a
    /// re-connect) starts from a clean slate. Centralised because three
    /// teardown paths used to maintain it independently and were already
    /// drifting out of sync as new fields were added.
    private func clearSessionState() {
        finishAllChannels()
        ptyChannels.removeAll()
        ptys = []
        views = []
        activeViewID = nil
        clients = []
        runningCommand = [:]
        shellKind = [:]
        shellContext = [:]
    }

    // MARK: - Sessions

    func refreshSessions() async {
        guard let rpc else { return }
        do {
            let r = try await rpc.call("session.list", as: MotifProto.SessionListResult.self)
            sessions = r.sessions
        } catch {
            log.error("session.list: \(String(describing: error), privacy: .public)")
        }
    }

    func createSession(name: String, workdir: String) async throws -> MotifProto.SessionInfo {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "session.create",
            params: MotifProto.SessionCreateParams(name: name, workdir: workdir),
            as: MotifProto.SessionCreateResult.self
        )
        sessions.append(r.session)
        return r.session
    }

    /// Leave the currently attached session but keep the WS connection
    /// alive — we go back to .connected so the UI lands on the session
    /// picker again. Different from `disconnect()` which closes the WS.
    func detach() async {
        // Voluntary detach = clean exit. If the user re-attaches later,
        // they expect the same full-scrollback experience as the first
        // attach, not a diff from where they detached. Drop the marker.
        if case .attached(let name) = state {
            resumeSeqs.removeValue(forKey: name)
        }
        // Also drop the auto-reattach intent — the user explicitly chose
        // to leave, so a subsequent reconnect should land them on the
        // session picker, not silently rejoin the session they just left.
        intendedSession = nil
        guard let rpc else {
            state = .disconnected
            return
        }
        do {
            _ = try await rpc.call("session.detach")
        } catch {
            log.error("session.detach: \(String(describing: error), privacy: .public)")
            // Even if the server-side detach failed, locally tear down so
            // the user can still get back to the picker.
        }
        clearSessionState()
        state = .connected
    }

    func attach(sessionName: String) async throws {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        // Resume marker (set by a previous handleConnectionLost on this
        // same session) → ask the server for events since that seq only.
        // `nil` => first attach this WS lifetime → server defaults to 0 =
        // full ring replay.
        let resume = resumeSeqs[sessionName]
        if let r = resume {
            log.notice("attaching to \(sessionName, privacy: .public) with resume seq=\(r, privacy: .public)")
        }
        let r = try await rpc.call(
            "session.attach",
            params: MotifProto.SessionAttachParams(name: sessionName, last_seq: resume, term_fg: nil, term_bg: nil),
            as: MotifProto.SessionAttachResult.self
        )
        ptys = r.ptys ?? []
        // Pre-create channels for every PTY in the attach response so
        // pty.output bytes that arrive before any TerminalView exists are
        // captured into the ring buffer instead of being dropped.
        for pty in ptys { _ = ensureChannel(pty.id) }
        views = r.views ?? []
        activeViewID = r.active_view
        clients = r.clients ?? []
        lastSeq = r.last_seq ?? 0
        // Marker has been spent. Replayed events will arrive as normal
        // notifications and re-populate lastSeq via SeqPeek; if the WS
        // dies again, handleConnectionLost will re-snapshot.
        resumeSeqs.removeValue(forKey: sessionName)
        // Remember the intent so a future connection drop + reconnect can
        // auto-reattach without user action.
        intendedSession = sessionName
        state = .attached(session: sessionName)
        log.notice("attached to \(sessionName, privacy: .public): \(self.ptys.count, privacy: .public) ptys, \(self.views.count, privacy: .public) views, \(self.clients.count, privacy: .public) peers")
    }

    /// Tear down a session entirely (kills its PTYs, drops it from the
    /// session list everywhere). The server broadcasts `session_closed`
    /// shape via the connection drop on attached clients — for the
    /// caller, we just refresh `sessions` after the call.
    func destroySession(name: String) async throws {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        _ = try await rpc.call(
            "session.destroy",
            params: MotifProto.SessionDestroyParams(name: name)
        )
        sessions.removeAll { $0.name == name }
        // The session and its ring are gone server-side; any saved
        // resume seq for it is useless and would be wrong if a future
        // session was created with the same name. Same reasoning for
        // the auto-reattach intent: don't try to re-enter a session
        // that no longer exists.
        resumeSeqs.removeValue(forKey: name)
        if intendedSession == name {
            intendedSession = nil
        }
    }

    // MARK: - PTYs

    func createPty(cmd: String? = nil, cwd: String? = nil, cols: UInt16 = 80, rows: UInt16 = 24) async throws -> MotifProto.PtyInfo {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "pty.create",
            params: MotifProto.PtyCreateParams(cmd: cmd, cwd: cwd, env: nil, cols: cols, rows: rows),
            as: MotifProto.PtyCreateResult.self
        )
        ptys.append(r.info)
        _ = ensureChannel(r.info.id)
        return r.info
    }

    func write(ptyID: String, data: Data) async {
        guard let rpc else { return }
        do {
            _ = try await rpc.call("pty.write", params: MotifProto.PtyWriteParams(pty_id: ptyID, data: data))
        } catch {
            log.error("pty.write: \(String(describing: error), privacy: .public)")
        }
    }

    func resize(ptyID: String, cols: UInt16, rows: UInt16) async {
        guard let rpc else { return }
        do {
            _ = try await rpc.call("pty.resize", params: MotifProto.PtyResizeParams(pty_id: ptyID, cols: cols, rows: rows))
        } catch {
            log.error("pty.resize: \(String(describing: error), privacy: .public)")
        }
    }

    func kill(ptyID: String) async {
        guard let rpc else { return }
        do {
            _ = try await rpc.call("pty.kill", params: MotifProto.PtyKillParams(pty_id: ptyID))
        } catch {
            log.error("pty.kill: \(String(describing: error), privacy: .public)")
        }
    }

    /// Find the view id whose spec wraps `ptyID`. Used by the tab UI to
    /// translate a PTY-tab tap into a `view.activate` RPC.
    func viewID(forPty ptyID: String) -> String? {
        for v in views {
            if case .pty(let pid) = v.spec, pid == ptyID { return v.id }
        }
        return nil
    }

    /// Tell the server which view we're focusing. Beyond mirroring the
    /// active-tab marker across clients, this also claims the PTY's
    /// primary status: the server's `view.activate` handler calls
    /// `mark_primary`, so the master immediately snaps to our reported
    /// dimensions instead of staying pinned to whichever client wrote
    /// most recently.
    func activateView(viewID: String) async {
        guard let rpc else { return }
        do {
            _ = try await rpc.call(
                "view.activate",
                params: MotifProto.ViewActivateParams(view_id: viewID)
            )
        } catch {
            log.error("view.activate: \(String(describing: error), privacy: .public)")
        }
    }

    /// Open a server-side view (preview / diff / image / pty wrapper).
    /// On success, the server broadcasts `view.opened` (and, when
    /// `activate=true`, `view.active_changed`); we also append directly
    /// here so the caller can rely on `views` being up-to-date by the
    /// time the await returns — handy for "open + immediately scroll
    /// to it".
    @discardableResult
    func openView(spec: MotifProto.ViewSpec, activate: Bool = true) async throws -> MotifProto.ViewInfo {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "view.open",
            params: MotifProto.ViewOpenParams(spec: spec, activate: activate),
            as: MotifProto.ViewOpenResult.self
        )
        if !views.contains(where: { $0.id == r.view.id }) {
            views.append(r.view)
        }
        return r.view
    }

    func closeView(viewID: String) async {
        guard let rpc else { return }
        do {
            _ = try await rpc.call(
                "view.close",
                params: MotifProto.ViewCloseParams(view_id: viewID)
            )
        } catch {
            log.error("view.close: \(String(describing: error), privacy: .public)")
        }
    }

    func moveView(viewID: String, toIndex: Int) async {
        guard let rpc else { return }
        do {
            _ = try await rpc.call(
                "view.move",
                params: MotifProto.ViewMoveParams(view_id: viewID, to_index: toIndex)
            )
        } catch {
            log.error("view.move: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - fs / git

    func fsTree(path: String, depth: UInt32 = 1, showHidden: Bool = false) async throws -> MotifProto.FsTreeResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "fs.tree",
            params: MotifProto.FsTreeParams(path: path, depth: depth, show_hidden: showHidden),
            as: MotifProto.FsTreeResult.self
        )
    }

    /// Read a single file. `maxBytes == nil` lets the server cap at its
    /// default (10 MB per the protocol). Returns the raw `FsReadResult`
    /// — caller decodes `content_b64` only when `binary == false`.
    func fsRead(path: String, maxBytes: UInt64? = nil) async throws -> MotifProto.FsReadResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "fs.read",
            params: MotifProto.FsReadParams(path: path, max_bytes: maxBytes),
            as: MotifProto.FsReadResult.self
        )
    }

    func gitStatus(cwd: String? = nil) async throws -> MotifProto.GitStatusResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "git.status",
            params: MotifProto.GitStatusParams(cwd: cwd),
            as: MotifProto.GitStatusResult.self
        )
    }

    /// Returns the unified-diff text, or "" when there are no changes.
    /// `path == nil` => full repo diff. `staged` selects HEAD-vs-index
    /// (true) or index-vs-worktree (false).
    func gitDiff(path: String? = nil, staged: Bool, cwd: String? = nil) async throws -> String {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "git.diff",
            params: MotifProto.GitDiffParams(path: path, staged: staged, cwd: cwd),
            as: MotifProto.GitDiffResult.self
        )
        return r.patch
    }

    /// Per-file additions/deletions, same scope as `gitDiff`. Cheaper
    /// than parsing the full unified patch and used by GitDiffPanel's
    /// file picker to render `+N −M` chips next to each path.
    func gitDiffSummary(path: String? = nil, staged: Bool, cwd: String? = nil) async throws -> [MotifProto.DiffSummaryFile] {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "git.diffSummary",
            params: MotifProto.GitDiffParams(path: path, staged: staged, cwd: cwd),
            as: MotifProto.DiffSummaryResult.self
        )
        return r.files
    }

    /// Cheap file metadata. Used before a destructive UI action so we
    /// can surface "delete a 5 MB file?" or to confirm a path's type
    /// before opening a preview tab.
    func fsStat(path: String) async throws -> MotifProto.FsStatResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "fs.stat",
            params: MotifProto.FsStatParams(path: path),
            as: MotifProto.FsStatResult.self
        )
    }

    /// Write bytes to a file. `expectedSha256` enables optimistic-lock
    /// behavior: if the on-disk content has drifted, the server returns
    /// `Conflict (-32004)` and the caller can decide to reload or
    /// `force` an overwrite. Pass `nil` for "I'm creating this file"
    /// or "I genuinely don't care".
    @discardableResult
    func fsWrite(path: String, contentB64: String, expectedSha256: String?, force: Bool) async throws -> MotifProto.FsWriteResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "fs.write",
            params: MotifProto.FsWriteParams(
                path: path,
                content_b64: contentB64,
                expected_sha256: expectedSha256,
                force: force
            ),
            as: MotifProto.FsWriteResult.self
        )
    }

    func fsMkdir(path: String) async throws {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        _ = try await rpc.call(
            "fs.mkdir",
            params: MotifProto.FsMkdirParams(path: path)
        )
    }

    func fsRemove(path: String) async throws {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        _ = try await rpc.call(
            "fs.remove",
            params: MotifProto.FsRemoveParams(path: path)
        )
    }

    func fsRename(from: String, to: String) async throws {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        _ = try await rpc.call(
            "fs.rename",
            params: MotifProto.FsRenameParams(from: from, to: to)
        )
    }

    /// Subscribe to a PTY's output stream. Each call returns a fresh
    /// AsyncStream that first replays the channel's ring buffer (so a
    /// SwiftTerm freshly created after a tab switch still sees recent
    /// scrollback), then forwards every subsequent live chunk. Multiple
    /// concurrent subscribers on the same PTY are fine — they all see the
    /// same bytes. If the PTY has already exited, the buffer is replayed
    /// and the stream finishes immediately after.
    func outputs(for ptyID: String) -> AsyncStream<Data> {
        let ch = ensureChannel(ptyID)
        let (stream, cont) = AsyncStream.makeStream(of: Data.self)
        let key = UUID()
        ch.subscribers[key] = cont
        cont.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ptyChannels[ptyID]?.subscribers.removeValue(forKey: key)
            }
        }
        for chunk in ch.buffer { cont.yield(chunk) }
        if ch.finished { cont.finish() }
        return stream
    }

    @discardableResult
    private func ensureChannel(_ ptyID: String) -> PtyChannel {
        if let ch = ptyChannels[ptyID] { return ch }
        let ch = PtyChannel()
        ptyChannels[ptyID] = ch
        return ch
    }

    private func appendOutput(ptyID: String, data: Data) {
        let ch = ensureChannel(ptyID)
        ch.buffer.append(data)
        ch.bufferBytes += data.count
        // Drop oldest chunks until we're back under the per-PTY budget.
        // Keep at least one chunk so a single oversized burst doesn't
        // wipe the buffer entirely.
        while ch.bufferBytes > maxBufferBytesPerPty && ch.buffer.count > 1 {
            let removed = ch.buffer.removeFirst()
            ch.bufferBytes -= removed.count
        }
        for (_, sub) in ch.subscribers { sub.yield(data) }
    }

    private func finishChannel(_ ptyID: String) {
        guard let ch = ptyChannels[ptyID] else { return }
        ch.finished = true
        for (_, sub) in ch.subscribers { sub.finish() }
        ch.subscribers.removeAll()
    }

    private func finishAllChannels() {
        for (_, ch) in ptyChannels {
            ch.finished = true
            for (_, sub) in ch.subscribers { sub.finish() }
            ch.subscribers.removeAll()
        }
    }

    // MARK: - Events

    private func handleEvent(_ event: RpcClient.Event) {
        // Server's seq is session-global and monotonic across every event
        // kind. Peek it via a tiny `{seq?}` shape so we update lastSeq for
        // pty.created / view.opened / git.changed / etc. too — otherwise a
        // long quiet stretch with no PTY output would leave our resume
        // marker stuck behind the live cursor.
        if let s = (try? event.decode(MotifProto.SeqPeek.self))?.seq {
            lastSeq = max(lastSeq, s)
        }
        switch event.method {
        case "pty.output":
            guard let payload = try? event.decode(MotifProto.PtyOutputEvent.self) else { return }
            appendOutput(ptyID: payload.pty_id, data: payload.data)

        case "pty.exited":
            guard let payload = try? event.decode(MotifProto.PtyExitedEvent.self) else { return }
            // Mark dead in our cached list + close out live subscribers.
            // Channel + ring buffer are kept so a tab activated after the
            // exit can still see what the PTY printed.
            if let i = ptys.firstIndex(where: { $0.id == payload.pty_id }) {
                ptys[i].alive = false
            }
            finishChannel(payload.pty_id)
            runningCommand.removeValue(forKey: payload.pty_id)
            shellKind.removeValue(forKey: payload.pty_id)
            shellContext.removeValue(forKey: payload.pty_id)

        case "pty.created":
            if let payload = try? event.decode(MotifProto.PtyCreatedEvent.self),
               !ptys.contains(where: { $0.id == payload.info.id })
            {
                ptys.append(payload.info)
                _ = ensureChannel(payload.info.id)
            }

        case "pty.resize":
            if let payload = try? event.decode(MotifProto.PtyResizeEvent.self),
               let i = ptys.firstIndex(where: { $0.id == payload.pty_id })
            {
                ptys[i].cols = payload.cols
                ptys[i].rows = payload.rows
            }

        case "pty.cwd_changed":
            if let payload = try? event.decode(MotifProto.PtyCwdChangedEvent.self),
               let i = ptys.firstIndex(where: { $0.id == payload.pty_id })
            {
                ptys[i].cwd = payload.cwd
            }

        case "pty.command_started":
            if let payload = try? event.decode(MotifProto.PtyCommandStartedEvent.self),
               !payload.text.isEmpty
            {
                runningCommand[payload.pty_id] = payload.text
            }

        case "pty.command_finished":
            if let payload = try? event.decode(MotifProto.PtyCommandFinishedEvent.self) {
                runningCommand.removeValue(forKey: payload.pty_id)
            }

        case "tree.changed":
            // We only need observers to know "something changed". The
            // payload's `paths` list is informational — leaving it
            // unparsed keeps the surface small. &+= so observers don't
            // miss a wraparound (extremely theoretical, but free).
            treeChangeTick &+= 1

        case "git.changed":
            // Same pattern as tree.changed: bump a tick so GitStatus /
            // GitDiffPanel re-fetch on the next observe.
            gitChangeTick &+= 1

        case "view.opened":
            if let payload = try? event.decode(MotifProto.ViewOpenedEvent.self),
               !views.contains(where: { $0.id == payload.view.id })
            {
                views.append(payload.view)
            }

        case "view.closed":
            if let payload = try? event.decode(MotifProto.ViewClosedEvent.self) {
                views.removeAll { $0.id == payload.view_id }
                if activeViewID == payload.view_id {
                    // Server will emit a follow-up `view.active_changed`
                    // (possibly with a fallback view). Clear ours now so
                    // the UI doesn't stay pointed at a missing view in
                    // the gap between the two events.
                    activeViewID = nil
                }
            }

        case "view.active_changed":
            if let payload = try? event.decode(MotifProto.ViewActiveChangedEvent.self) {
                activeViewID = payload.view_id
            }

        case "view.moved":
            if let payload = try? event.decode(MotifProto.ViewMovedEvent.self) {
                // Build a position map from the broadcast order; ids that
                // somehow aren't in our local `views` (desync) drop to
                // the tail in arrival order.
                let order = payload.order
                var rank: [String: Int] = [:]
                for (i, id) in order.enumerated() { rank[id] = i }
                views.sort { a, b in
                    let ra = rank[a.id] ?? Int.max
                    let rb = rank[b.id] ?? Int.max
                    return ra < rb
                }
            }

        case "client.joined":
            if let payload = try? event.decode(MotifProto.ClientJoinedEvent.self) {
                if let i = clients.firstIndex(where: { $0.id == payload.client_id }) {
                    clients[i].since = payload.since
                } else {
                    clients.append(MotifProto.ClientInfo(id: payload.client_id, since: payload.since))
                }
            }

        case "client.left":
            if let payload = try? event.decode(MotifProto.ClientLeftEvent.self) {
                clients.removeAll { $0.id == payload.client_id }
            }

        case "pty.shell_bootstrapped":
            if let payload = try? event.decode(MotifProto.PtyShellBootstrappedEvent.self) {
                shellKind[payload.pty_id] = payload.shell
            }

        case "pty.shell_context":
            if let payload = try? event.decode(MotifProto.PtyShellContextEvent.self) {
                shellContext[payload.pty_id] = payload.ctx
            }

        default:
            // Block-related events (`pty.prompt_started`,
            // `pty.prompt_ended`) are intentionally ignored — the iOS
            // client doesn't render the block model yet.
            break
        }
    }
}
