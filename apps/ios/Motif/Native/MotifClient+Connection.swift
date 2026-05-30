import Foundation
import OSLog
import TalkerCommonLogging

// Connection lifecycle: dialling motifd over tsnet, ping/pre-warm helpers,
// involuntary-drop handling, and teardown.
extension MotifClient {
    func connect(server: MotifServer, tailscale: TailscaleManager, force: Bool = false) async {
        if !force {
            if case .connected = state { return }
            if case .attached = state { return }
        } else if rpc != nil {
            // Forced re-dial: the way we reach motifd changed (most often a
            // tsnet node restart that moved the loopback SOCKS5 proxy to a
            // new port, leaving our URLSession pointed at a dead one — the
            // proxy is captured at connect time and never mutates). Tear down
            // the stale transport so it's rebuilt below. Preserve the session
            // view + `intendedSession` so auto-reattach lands the user back
            // where they were.
            if let rpc { carriedPtyCursors = await rpc.ptyCursors() }
            eventTask?.cancel()
            eventTask = nil
            if let rpc { await rpc.close() }
            rpc = nil
        }
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
        let proxyCount = urlSessionConfig.proxyConfigurations.count
        let proxyDesc = urlSessionConfig.proxyConfigurations.first.map { String(describing: $0) } ?? "(none)"
        log.notice("urlSession proxyCount=\(proxyCount, privacy: .public) first=\(proxyDesc, privacy: .public)")
        infoLog("[MotifClient] urlSession proxyCount=\(proxyCount) first=\(proxyDesc)")

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

        log.notice("motifd target=\(server.name, privacy: .public) host=\(server.host, privacy: .public) resolved=\(resolvedHost, privacy: .public) port=\(server.port, privacy: .public) tokenLen=\(server.token.count, privacy: .public)")
        infoLog("[MotifClient] connect target=\(server.name) host=\(server.host) resolved=\(resolvedHost) port=\(server.port) tokenLen=\(server.token.count)")

        if case .tailscale = server.kind {
            // Pre-warm the magicsock path before we ask URLSession to open
            // anything. `state=Running` only means controlplane is up — the
            // first data packet to a specific peer still pays NAT discovery
            // / DERP fallback. This used to run in a background Task, which
            // let the first /ping race ahead and fail; a manual Retry then
            // worked because the background pre-warm had finished by then.
            let didPreWarm = await preWarmTsnetPath(host: resolvedHost, port: server.port, tailscale: tailscale)
            if didPreWarm {
                startTailscaleDiagnostics(host: resolvedHost, port: server.port, tailscale: tailscale)
            }
        }

        // New protocol: RPC runs over HTTP, server-pushed events / PTY
        // bytes go on separate WSes. No ?bin=1 codec negotiation
        // anymore — RPC bodies are JSON, PTY bytes are raw.
        let rpc = RpcClient()
        do {
            try await rpc.connect(urlSession: urlSession,
                                  host: resolvedHost,
                                  port: server.port,
                                  token: server.token,
                                  delegate: delegate)
            let ping = try await pingWithStartupRetry(rpc: rpc, server: server)
            guard ping.isMotifServer else {
                let endpoint = displayEndpoint(server: server, resolvedHost: resolvedHost)
                state = .failed(message: "A server answered at \(endpoint), but it is not motifd (service=\(ping.service)). Check the host and port.")
                return
            }
            log.notice("motifd ping ok version=\(ping.version, privacy: .public)")
            infoLog("[MotifClient] ping ok version=\(ping.version)")
        } catch {
            let friendly = friendlyConnectMessage(
                server: server,
                resolvedHost: resolvedHost,
                error: error
            )
            log.error("rpc connect: \(String(describing: error), privacy: .public)")
            infoLog("[MotifClient] rpc connect failed: \(error)")
            state = .failed(message: friendly)
            return
        }
        self.rpc = rpc
        // Resume per-PTY substreams from where the previous connection left
        // off so the auto-reattach below replays only the missed delta into
        // the surviving terminal surfaces. No-op on a first connect (empty).
        if !carriedPtyCursors.isEmpty {
            await rpc.seedPtyCursors(carriedPtyCursors)
            carriedPtyCursors = [:]
        }
        log.notice("connected to motifd as \(server.name, privacy: .public)")
        infoLog("[MotifClient] ws task resumed (state=connected)")
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
            infoLog("[MotifClient] auto re-attaching to \(name)")
            do {
                try await attach(sessionName: name)
                // Honor the tab the user switched to while offline: attach
                // just reseeded `activeViewID` from the server's stale
                // `active_view`, so push the local choice back if it differs
                // and still exists.
                if let pending = pendingLocalViewID {
                    if pending != activeViewID, views.contains(where: { $0.id == pending }) {
                        await activateView(viewID: pending)
                    }
                    pendingLocalViewID = nil
                }
            } catch {
                // Session was destroyed / renamed / otherwise gone. Stop
                // looping on the same failure; drop to `.connected` so the
                // user lands on the picker on their next interaction.
                log.error("auto re-attach \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                infoLog("[MotifClient] auto re-attach \(name) failed: \(error)")
                intendedSession = nil
                pendingLocalViewID = nil
                state = .connected
            }
        } else {
            state = .connected
        }
    }

    private func displayEndpoint(server: MotifServer, resolvedHost: String) -> String {
        if resolvedHost == server.host {
            return "\(server.host):\(server.port)"
        }
        return "\(server.host) (\(resolvedHost)):\(server.port)"
    }

    private func friendlyConnectMessage(
        server: MotifServer,
        resolvedHost: String,
        error: any Error
    ) -> String {
        let endpoint = displayEndpoint(server: server, resolvedHost: resolvedHost)

        if let rpcError = error as? RpcClient.RpcError {
            switch rpcError {
            case .decode(let message) where message.hasPrefix("ping response:"):
                return "Something answered at \(endpoint), but it did not return motifd's /ping response. Check that this host and port point to motifd."
            case .transport(let message) where message.contains("ping HTTP 404"):
                return "A server answered at \(endpoint), but /ping was not found. Update motifd on that machine, or check that the port points to motifd."
            case .transport(let message) where message.hasPrefix("ping HTTP"):
                return "A server answered at \(endpoint), but /ping returned \(message.replacingOccurrences(of: "ping ", with: "")). Check motifd's logs on the server."
            case .transport(let message):
                return "Could not verify motifd at \(endpoint). \(message)"
            case .notConnected:
                return "Could not start the motifd connection. Please retry."
            case .decode(let message):
                return "motifd answered at \(endpoint), but the response could not be decoded. \(message)"
            case .server(let code, let message):
                return "motifd rejected the request (\(code)): \(message)"
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .cannotFindHost:
                return "Could not find \(server.host). Check the hostname, or make sure Tailscale MagicDNS is working."
            case .cannotConnectToHost:
                return "Reached \(server.host), but port \(server.port) is not accepting connections. Make sure motifd is running and listening on that port."
            case .badURL:
                if server.kind == .tailscale {
                    return "Could not reach motifd through Tailscale at \(endpoint). Tailscale is connected, but /ping could not be opened. Check that motifd is running and the host/port are correct."
                }
                return "The server address \(endpoint) could not be opened. Check the host and port."
            case .timedOut:
                return "Timed out while probing \(endpoint). Make sure motifd is running and reachable over \(server.kind == .tailscale ? "Tailscale" : "the network")."
            case .networkConnectionLost:
                return "The connection dropped while probing \(endpoint). If this server uses Tailscale, wait for Tailscale to finish connecting and retry."
            case .notConnectedToInternet, .dataNotAllowed:
                return "This device is offline. Connect to the network and retry."
            case .cannotLoadFromNetwork:
                return "iOS could not load \(endpoint) from the network. Check local network permissions and connectivity."
            default:
                break
            }
        }

        return "Could not reach motifd at \(endpoint). \(String(describing: error))"
    }

    private func pingWithStartupRetry(rpc: RpcClient, server: MotifServer) async throws -> MotifProto.PingInfo {
        do {
            return try await rpc.ping()
        } catch {
            guard shouldRetryStartupPing(error) else { throw error }
            log.notice("startup ping failed once; retrying after warm-up: \(String(describing: error), privacy: .public)")
            infoLog("[MotifClient] startup ping retry after error: \(error)")
            try? await Task.sleep(for: .milliseconds(server.kind == .tailscale ? 900 : 350))
            return try await rpc.ping()
        }
    }

    private func shouldRetryStartupPing(_ error: any Error) -> Bool {
        if let rpcError = error as? RpcClient.RpcError {
            switch rpcError {
            case .transport(let message):
                if message.hasPrefix("ping HTTP 4") { return false }
                return true
            case .notConnected:
                return true
            case .decode, .server:
                return false
            }
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    private func startTailscaleDiagnostics(host: String, port: UInt16, tailscale: TailscaleManager) {
        Task { [weak self, tailscale, host, port] in
            // Diagnostic: prove the tailnet path can carry a plain-HTTP
            // request end-to-end without URLSession in the loop. Run this
            // off the critical connect path so a wedged tailnet dial can't
            // strand the UI on "Connecting…".
            let probe = await tailscale.rawHttpProbe(host: host, port: port, path: "/ping")
            guard let self else { return }
            log.notice("raw http probe status=\(probe.statusLine ?? "(nil)", privacy: .public) bytes=\(probe.bytesRead, privacy: .public) elapsed=\(probe.elapsedMs, privacy: .public)ms err=\(probe.error ?? "(none)", privacy: .public)")
            infoLog("[MotifClient] raw http probe status=\(probe.statusLine ?? "(nil)") bytes=\(probe.bytesRead) elapsed=\(probe.elapsedMs)ms err=\(probe.error ?? "(none)")")
        }
    }

    /// Best-effort TCP dial through tsnet to provoke the magicsock path
    /// setup before the WS upgrade. Races the dial against an 8s timeout
    /// so a wedged path doesn't stall the connect indefinitely — if it
    /// times out or errors, we still proceed to the WS attempt (which
    /// has its own 15s URLRequest timeout). The probe connection is
    /// closed immediately; we just want the side effect of building the
    /// peer route in libtailscale.
    private func preWarmTsnetPath(host: String, port: UInt16, tailscale: TailscaleManager) async -> Bool {
        let start = Date()
        let result: Result<Void, any Error> = await withCheckedContinuation { continuation in
            let completion = PreWarmCompletion()
            Task.detached(priority: .utility) { [tailscale, host, port] in
                do {
                    let conn = try await tailscale.dial(host: host, port: port)
                    await conn.close()
                    completion.resume(continuation, with: .success(()))
                } catch {
                    completion.resume(continuation, with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
                completion.resume(continuation, with: .failure(PreWarmTimeout()))
            }
        }

        switch result {
        case .success:
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            log.notice("tsnet path pre-warmed to \(host, privacy: .public):\(port, privacy: .public) in \(ms, privacy: .public)ms")
            infoLog("[MotifClient] tsnet pre-warm ok \(host):\(port) (\(ms)ms)")
            return true
        case .failure(let error):
            // Don't fail the connect; the WS attempt will surface the real
            // error if the path really is broken.
            log.warning("tsnet pre-warm dial failed: \(String(describing: error), privacy: .public)")
            infoLog("[MotifClient] tsnet pre-warm failed: \(error)")
            return false
        }
    }

    private final class PreWarmCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resume(
            _ continuation: CheckedContinuation<Result<Void, any Error>, Never>,
            with result: Result<Void, any Error>
        ) {
            lock.lock()
            let shouldResume = !didResume
            didResume = true
            lock.unlock()

            if shouldResume {
                continuation.resume(returning: result)
            }
        }
    }

    private struct PreWarmTimeout: Error, CustomStringConvertible {
        var description: String { "pre-warm dial timed out" }
    }

    /// Called once the events stream finishes. If the user explicitly
    /// disconnect()ed we already cleaned up; only act when the WS died
    /// out from under us (state is .connecting/.connected/.attached).
    func handleConnectionLost() async {
        switch state {
        case .disconnected, .failed:
            return
        case .connecting, .connected, .attached:
            break
        }
        // Snapshot the resume marker so the next attach replays session
        // events from here. lastSeq stays meaningful — we deliberately do
        // NOT clear session state on an involuntary drop (see below).
        if case .attached(let name) = state, lastSeq > 0 {
            resumeSeqs[name] = lastSeq
            log.notice("saved resume marker for \(name, privacy: .public) at seq=\(self.lastSeq, privacy: .public)")
        }
        log.notice("connection lost — preserving session view for offline use")
        infoLog("[MotifClient] connection lost; preserving session state")
        // Carry the per-PTY byte cursors so the successor connection resumes
        // each substream from where it left off.
        if let rpc { carriedPtyCursors = await rpc.ptyCursors() }
        eventTask?.cancel()
        eventTask = nil
        if let rpc { await rpc.close() }
        rpc = nil
        // Unlike a voluntary disconnect/detach, do NOT clear ptys/views/
        // channels here. Keeping them lets the terminal stay on screen with
        // its scrollback (the Ghostty runtimes survive because `livePtyIDs`
        // stays non-empty, so SessionView won't prune them), and the live
        // pty pumps stay parked on their channels until `reactivate()` after
        // reconnect feeds them again. `intendedSession` drives auto-reattach.
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
        carriedPtyCursors = [:]
        pendingLocalViewID = nil
        intendedSession = nil
        lastSeq = 0
        state = .disconnected
    }

    /// Drop every per-session piece of state so a fresh attach (or a
    /// re-connect) starts from a clean slate. Centralised because three
    /// teardown paths used to maintain it independently and were already
    /// drifting out of sync as new fields were added.
    func clearSessionState() {
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
}
