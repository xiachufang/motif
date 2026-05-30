import Foundation

// View open / close / move / activate + terminal palette + primary reclaim.
extension MotifClient {
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
    /// Switch the active view locally without a server round-trip. Used
    /// while offline so the user can flip between already-open terminals and
    /// read their retained scrollback. When the link is up we go through
    /// `activateView` instead and let the server's `view.active_changed`
    /// event drive `activeViewID`. On reconnect, `attach()` reseeds
    /// `activeViewID` from the server's `active_view`.
    func selectViewLocally(viewID: String) {
        guard views.contains(where: { $0.id == viewID }) else { return }
        activeViewID = viewID
        pendingLocalViewID = viewID
    }

    /// Switch the active view server-authoritatively, but flip the local
    /// `activeViewID` *optimistically* first so the tab changes the instant
    /// the user taps — instead of stalling a full RTT until the server's
    /// `view.active_changed` echo arrives. The echo (or a peer's switch)
    /// still flows through `handleEvent` and stays authoritative; on RPC
    /// failure we roll back, but only if nothing else moved focus meanwhile.
    /// Update the cached terminal palette. Stores it for the next
    /// `session.attach` and, if already attached on a live link, pushes it to
    /// the server immediately via `session.set_palette` so programs started
    /// after a mid-session theme change see the new colours. No-op when the
    /// palette is unchanged so font-size edits don't trigger a needless RPC.
    func setTerminalPalette(fg: String?, bg: String?, theme: String?) {
        guard fg != termFg || bg != termBg || theme != termTheme else { return }
        termFg = fg
        termBg = bg
        termTheme = theme
        guard let rpc, case .attached = state else { return }
        Task {
            do {
                _ = try await rpc.call(
                    "session.set_palette",
                    params: MotifProto.SessionSetPaletteParams(term_fg: fg, term_bg: bg, theme: theme)
                )
            } catch {
                log.error("session.set_palette: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func activateView(viewID: String) async {
        guard let rpc else { return }
        let previous = activeViewID
        activeViewID = viewID
        do {
            _ = try await rpc.call(
                "view.activate",
                params: MotifProto.ViewActivateParams(view_id: viewID)
            )
        } catch {
            log.error("view.activate: \(String(describing: error), privacy: .public)")
            if activeViewID == viewID { activeViewID = previous }
        }
    }

    /// (Re)claim PTY primary by re-asserting our current active view to the
    /// server. `/pty` no longer carries a primary flag — the client that's
    /// actually being used reclaims primary on foreground / attach by
    /// re-activating its view. The server skips the `view.active_changed`
    /// broadcast when the active view is unchanged, so peers aren't disturbed;
    /// only `mark_primary` runs. No-op when backgrounded, detached, or there's
    /// no active view.
    func reclaimPrimary() {
        guard isForeground, case .attached = state, let rpc, let vid = activeViewID else { return }
        Task {
            do {
                _ = try await rpc.call(
                    "view.activate",
                    params: MotifProto.ViewActivateParams(view_id: vid)
                )
            } catch {
                log.error("view.activate (reclaim primary): \(String(describing: error), privacy: .public)")
            }
        }
        // Also re-assert this device's theme + palette as the session's, so the
        // foreground client's appearance wins and shells match what it renders.
        guard termFg != nil || termBg != nil || termTheme != nil else { return }
        Task {
            do {
                _ = try await rpc.call(
                    "session.set_palette",
                    params: MotifProto.SessionSetPaletteParams(term_fg: termFg, term_bg: termBg, theme: termTheme)
                )
            } catch {
                log.error("session.set_palette (reclaim): \(String(describing: error), privacy: .public)")
            }
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
}
