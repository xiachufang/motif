import Foundation

// Server-pushed event fan-in. Translates RpcClient notifications into
// observable state mutations.
extension MotifClient {
    func handleEvent(_ event: RpcClient.Event) {
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

        case "session.theme_changed":
            // Adopt the session-wide theme set by the driving client so the
            // whole UI renders the same way across clients.
            if let payload = try? event.decode(MotifProto.SessionThemeChangedEvent.self) {
                sessionTheme = payload.theme
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
