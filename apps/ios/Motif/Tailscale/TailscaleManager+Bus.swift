import Foundation
import TalkerCommonLogging
@preconcurrency import TailscaleKit

// IPN bus fan-in: translates tsnet `Notify` messages into `state` and the
// datapath-health hints. `BusConsumer` lives here too so `busDidReceive` /
// `busDidError` can stay file-private to their only caller.
extension TailscaleManager {
    /// Internal callback path: BusConsumer is an actor so it can implement
    /// the TailscaleKit MessageConsumer protocol. It hops back to MainActor
    /// to mutate `state` on the manager.
    fileprivate func busDidReceive(notify: Ipn.Notify) {
        if let s = notify.State {
            infoLog("[Tailscale] ipn=\(s) self=\(state)")
        }
        // Diagnostic: log every Notify field present so we can see exactly
        // what tsnet on iOS emits during the handshake. Trim down once the
        // login flow is verified working end-to-end.
        // Diagnostic breadcrumb: log just the high-signal fields. Engine
        // notifications fire every ~3s during normal operation so we keep
        // them quiet (the .Engine path below uses .debug).
        if notify.State != nil || notify.BrowseToURL != nil || notify.LoginFinished != nil || notify.ErrMessage != nil {
            var fields: [String] = []
            if let s = notify.State        { fields.append("state=\(s)") }
            if notify.BrowseToURL != nil   { fields.append("BrowseToURL=set") }
            if notify.LoginFinished != nil { fields.append("LoginFinished") }
            if let e = notify.ErrMessage   { fields.append("ErrMessage=\(e)") }
            log.notice("Notify: \(fields.joined(separator: ", "), privacy: .public)")
        }

        if let urlString = notify.BrowseToURL, let url = URL(string: urlString) {
            log.notice("BrowseToURL: \(urlString, privacy: .public)")
            state = .needsAuth(url: url)
        }
        if let ipnState = notify.State {
            switch ipnState {
            case .Running:
                Task { await self.refreshAddresses() }
            case .NeedsLogin:
                // tsnet has confirmed there's no usable cached login. Push
                // the interactive flow once so the bus emits BrowseToURL.
                // (Skip if we've already pushed it for this node — repeated
                // calls would just churn the URL.)
                if !loginInteractivePushed, let api = apiClient {
                    loginInteractivePushed = true
                    Task { [log] in
                        do {
                            try await api.startLoginInteractive()
                            log.notice("startLoginInteractive ok (state=NeedsLogin)")
                        } catch {
                            log.error("startLoginInteractive: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            case .Stopped:
                state = .stopped
            default:
                break
            }
        }

        // EngineStatus arrives every ~3s. A live-peer count dropping to
        // zero while we think we're running is a cheap early hint that the
        // datapath may be gone; confirm via the LocalAPI before reacting.
        if let engine = notify.Engine {
            let live = engine.NumLive
            let prev = lastNumLive
            lastNumLive = live
            if let prev, prev != live {
                infoLog("[Tailscale] engine NumLive \(prev) -> \(live) (state=\(state))")
            }
            if let prev, prev > 0, live == 0, case .running = state {
                Task { await self.checkHealthOnce() }
            }
        }
    }

    fileprivate func busDidError(_ error: any Error) {
        log.error("IPN bus error: \(String(describing: error), privacy: .public)")
    }
}

actor BusConsumer: MessageConsumer {
    weak var manager: TailscaleManager?

    init(manager: TailscaleManager) {
        self.manager = manager
    }

    func notify(_ notify: Ipn.Notify) {
        Task { @MainActor [weak manager] in
            manager?.busDidReceive(notify: notify)
        }
    }

    func error(_ error: any Error) {
        Task { @MainActor [weak manager] in
            manager?.busDidError(error)
        }
    }
}
