import Foundation
import TalkerCommonLogging

// Datapath health: reconciling `state` with tsnet's real reachability,
// recovery polling, and node rebuild when the LocalAPI listener dies.
extension TailscaleManager {
    /// Reconcile `state` with tsnet's actual view of tailnet reachability.
    ///
    /// libtailscale exposes no push event for a dropped datapath (the IPN
    /// `State` stays `.Running` through transient drops, and `Notify` has
    /// no health field), so the only way to notice a connection the system
    /// tore down — e.g. while the app was suspended in the background — is
    /// to ask the LocalAPI. Call this on foreground (`scenePhase` → active)
    /// and on a NumLive drop. No-op unless we believe the node is up.
    func revalidate() async {
        switch state {
        case .running, .degraded: break
        default:
            infoLog("[Tailscale] revalidate: skip (state=\(state))")
            return
        }
        infoLog("[Tailscale] revalidate: begin (state=\(state))")
        await checkHealthOnce()
    }

    /// One `backendStatus()` probe. Healthy → `.running` (with fresh IPs);
    /// unhealthy → `.degraded` and a recovery poll until tsnet comes back.
    func checkHealthOnce() async {
        if isRestarting { return }
        guard let api = apiClient else {
            infoLog("[Tailscale] health probe: apiClient is nil — cannot probe (state=\(state))")
            return
        }
        let healthy: Bool
        let reason: String
        var probeThrew = false
        do {
            let status = try await api.backendStatus()
            let online = status.SelfStatus?.Online ?? false
            healthy = status.BackendState == "Running" && online
            reason = status.Health?.first ?? "tailnet \(status.BackendState)"
            infoLog(
                "[Tailscale] health probe: backend=\(status.BackendState) online=\(online) "
                + "health=\(status.Health ?? []) numLive=\(lastNumLive.map(String.init) ?? "nil") "
                + "-> \(healthy ? "healthy" : "unhealthy")")
        } catch {
            healthy = false
            probeThrew = true
            reason = "status unavailable"
            infoLog("[Tailscale] health probe failed: \(error)")
        }

        // A successful probe — even one reporting the datapath down — proves
        // the LocalAPI is alive, so reset the dead-listener counter.
        consecutiveProbeFailures = probeThrew ? consecutiveProbeFailures + 1 : 0

        if healthy {
            let wasDegraded: Bool
            if case .running = state { wasDegraded = false } else { wasDegraded = true }
            stopHealthMonitor()
            // Avoid re-emitting `.running` (and its addr fetch) on every
            // healthy poll — only refresh when we're recovering from a
            // non-running state.
            if wasDegraded {
                infoLog("[Tailscale] health recovered (state=\(state)) -> running")
                await refreshAddresses()
            }
            return
        }

        let next = State.degraded(reason: reason)
        if state != next {
            state = next
            infoLog("[Tailscale] degraded: \(reason)")
        }

        // Two flavours of unhealthy:
        //  - LocalAPI reachable but datapath down (probe succeeded, online=
        //    false): tsnet re-establishes the tunnel on its own — keep polling.
        //  - LocalAPI unreachable N times running (probe keeps throwing, e.g.
        //    ECONNREFUSED on lo0 after a long suspend): the tsnet loopback
        //    listener is gone and polling it will never recover. Rebuild.
        if consecutiveProbeFailures >= Self.probeFailureRestartThreshold {
            infoLog(
                "[Tailscale] LocalAPI unreachable \(consecutiveProbeFailures)x — restarting node")
            await restartNode()
        } else {
            startHealthMonitor()
        }
    }

    /// Tear down and re-create the tsnet node in place. Used when the LocalAPI
    /// loopback listener has died (long app suspend) and passive polling can't
    /// recover it. Cached credentials in the state dir let `start()` resume
    /// without a fresh login. Existing tailnet connections drop; upper layers
    /// reconnect on their own.
    private func restartNode() async {
        guard !isRestarting else { return }
        isRestarting = true
        infoLog("[Tailscale] restartNode: tearing down")
        await teardown()  // also resets consecutiveProbeFailures
        infoLog("[Tailscale] restartNode: starting fresh node")
        // teardown() leaves state as-is (.degraded); start() guards only on
        // .running/.starting, so it proceeds and flips state to .starting.
        isRestarting = false
        await start(authKey: nil)
    }

    /// Spawn the recovery poll if it isn't already running. tsnet keeps
    /// trying to re-establish the tunnel on its own while the process is
    /// alive, so polling `backendStatus()` here is purely to observe that
    /// recovery and flip `state` back — no app traffic required.
    private func startHealthMonitor() {
        guard healthMonitorTask == nil else { return }
        infoLog("[Tailscale] health monitor: started (poll every 3s)")
        healthMonitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                tick += 1
                infoLog("[Tailscale] health monitor: poll #\(tick)")
                await self.checkHealthOnce()
            }
            infoLog("[Tailscale] health monitor: loop exited (cancelled)")
        }
    }

    private func stopHealthMonitor() {
        if healthMonitorTask != nil {
            infoLog("[Tailscale] health monitor: stopped")
        }
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }
}
