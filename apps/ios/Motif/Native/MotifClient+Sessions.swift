import Foundation

// Session list / create / attach / detach / destroy.
extension MotifClient {
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
        pendingLocalViewID = nil
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
            // Only a foreground (in-use) client drives the session palette/theme;
            // a background reattach adopts the server's instead of overriding.
            params: MotifProto.SessionAttachParams(
                name: sessionName,
                last_seq: resume,
                term_fg: isForeground ? termFg : nil,
                term_bg: isForeground ? termBg : nil,
                theme: isForeground ? termTheme : nil
            ),
            as: MotifProto.SessionAttachResult.self
        )
        ptys = r.ptys ?? []
        for pty in ptys { _ = ensureChannel(pty.id) }
        views = r.views ?? []
        activeViewID = r.active_view
        sessionTheme = r.theme
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
        // /pty no longer claims primary on connect — re-assert our active view
        // so this client owns primary if it's the one in the foreground.
        reclaimPrimary()
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
}
