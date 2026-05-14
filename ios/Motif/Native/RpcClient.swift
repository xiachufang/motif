import Foundation
import OSLog
import TalkerCommonSync

/// Coordinator-style client for the new motif protocol.
///
/// API surface is preserved from the original WS-multiplexed version so
/// `MotifClient` / `GitDiffPanel` / etc. don't need consumer-side rewires
/// beyond the connect path:
///
///   - `connect(urlSession:host:port:token:delegate:)` — opens HTTP +
///      /events WS. PTY WSes are opened lazily on attach response /
///      pty.create.
///   - `call<P, R>(method:params:as:)` — same shape as before.
///   - `events: AsyncStream<Event>` — receives both /events frames AND
///      synthesized `pty.output` events from per-PTY WSes.
///   - `close()` — tears down everything.
///
/// Routing rules (mirror the Rust Coordinator):
///   - `session.attach` → HTTP POST; on success, store session_id, open
///      /events, open one /pty/<id> per attached PTY.
///   - `session.detach` → close PTY WSes + events WS, then HTTP POST.
///   - `pty.write`      → bytes pushed to the matching PTY's stdin
///      channel (NOT an HTTP call).
///   - `pty.create`     → HTTP POST; on success, open /pty/<id> as primary.
///   - `pty.kill`       → HTTP POST; afterwards close the PTY WS.
///   - everything else  → HTTP POST passthrough.

/// Wire envelope for an HTTP RPC request body. Just the params — the
/// server-side `http_rpc::rpc_dispatch` adds the JSON-RPC envelope.
private struct RpcEmpty: Encodable, Decodable {}

/// Whole-frame Decodable used by /events to extract typed event
/// `params` (e.g. PtyOutputEvent) in one JSONDecoder pass.
private struct NotificationEnvelope<P: Decodable>: Decodable {
    let method: String
    let params: P
}

/// Server's structured error envelope (`crates/motif-proto/src/error.rs`
/// `RpcError`). Returned in the HTTP body on 4xx.
private struct RpcErrorPayload: Decodable {
    let code: Int
    let message: String
}

/// URLSession delegate that captures WebSocket lifecycle events and
/// surfaces them via OSLog. Reused unchanged from the old transport
/// since the /events and /pty/<id> WSes have the same upgrade dance.
final class WSLogDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "RpcClient.ws")

    private struct OpenState {
        var result: Result<Void, any Error>?
        var continuations: [CheckedContinuation<Void, any Error>] = []
    }
    private let openState = Lock<OpenState>(OpenState())

    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let immediate: Result<Void, any Error>? = openState.withLock { state in
                if let r = state.result { return r }
                state.continuations.append(cont)
                return nil
            }
            if let r = immediate {
                switch r {
                case .success:        cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }

    private func resolveOpen(_ result: Result<Void, any Error>) {
        let waiters: [CheckedContinuation<Void, any Error>] = openState.withLock { state in
            if state.result != nil { return [] }
            state.result = result
            let w = state.continuations
            state.continuations.removeAll()
            return w
        }
        for cont in waiters {
            switch result {
            case .success:        cont.resume()
            case .failure(let e): cont.resume(throwing: e)
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        log.notice("ws didOpen (protocol=\(proto ?? "(none)", privacy: .public))")
        FileLog.note("ws", "didOpen protocol=\(proto ?? "(none)")")
        resolveOpen(.success(()))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "(none)"
        log.error("ws didClose code=\(closeCode.rawValue, privacy: .public) reason=\(reasonStr, privacy: .public)")
        FileLog.note("ws", "didClose code=\(closeCode.rawValue) reason=\(reasonStr)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            resolveOpen(.failure(error))
        } else {
            resolveOpen(.success(()))
        }
        if let error {
            log.error("ws task didComplete error: \(String(describing: error), privacy: .public)")
            FileLog.note("ws", "didComplete err \(error)")
        } else {
            log.notice("ws task didComplete (no error)")
        }
    }
}

actor RpcClient {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "RpcClient")

    enum RpcError: Error, CustomStringConvertible {
        case notConnected
        case decode(String)
        case server(code: Int, message: String)
        case transport(String)

        var description: String {
            switch self {
            case .notConnected:         return "rpc: not connected"
            case .decode(let m):        return "rpc: decode \(m)"
            case .server(let c, let m): return "rpc \(c): \(m)"
            case .transport(let m):     return "rpc transport: \(m)"
            }
        }
    }

    /// A server-pushed notification (no id). Receives both /events
    /// frames (decoded JSON) and synthesized pty.output bursts.
    struct Event: Sendable {
        let method: String
        fileprivate let frame: Data

        /// Decode the notification's `params` into a method-specific
        /// Codable. The frame is always JSON now (the new protocol
        /// drops the msgpack codec — PTY bytes don't go through
        /// JSON-RPC anymore, they're raw on /pty/<id>).
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            return try JSONDecoder().decode(NotificationEnvelope<T>.self, from: frame).params
        }
    }

    private static let largeFrameBytes = 32 * 1024
    private static let slowStageMs:    Double = 5

    private var urlSession: URLSession?
    private var host:       String = ""
    private var port:       UInt16 = 0
    private var token:      String = ""
    private var delegate:   WSLogDelegate?

    /// Set by `session.attach`. Echoed back on every subsequent HTTP
    /// call (X-Motif-Session header) and on /events / /pty/<id> WS
    /// upgrades (?session=).
    private var sessionID:  String?

    /// /events WS task + receive loop. Replaced (with old aborted)
    /// on re-attach.
    private var eventsTask:      URLSessionWebSocketTask?
    private var eventsRecvTask:  Task<Void, Never>?
    private var eventsHeartbeat: Task<Void, Never>?
    private var eventsLastRecv:  Date = Date()

    /// Per-PTY connection state. Lazily filled when MotifClient
    /// observes a PTY (attach response or pty.created).
    private struct PtyChannel {
        var task:        URLSessionWebSocketTask
        var recvTask:    Task<Void, Never>
        var heartbeat:   Task<Void, Never>
        var lastRecv:    Date
        var shell:       ShellState
    }
    private var ptys: [String: PtyChannel] = [:]

    private var eventContinuation: AsyncStream<Event>.Continuation?
    let events: AsyncStream<Event>

    private let pingInterval:  TimeInterval = 20
    private let idleTimeout:   TimeInterval = 45
    private let heartbeatTick: TimeInterval = 10

    init() {
        var cont: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.eventContinuation = cont
    }

    /// New connect: caller supplies a configured URLSession (for tsnet
    /// proxy routing or default), plus the unhashed host/port/token.
    /// No WS handshake here — RPC is HTTP. The /events WS is opened
    /// lazily after session.attach.
    func connect(urlSession: URLSession, host: String, port: UInt16, token: String, delegate: WSLogDelegate) async throws {
        self.urlSession = urlSession
        self.host  = host
        self.port  = port
        self.token = token
        self.delegate = delegate
        log.notice("rpc.connect target=\(host, privacy: .public):\(port, privacy: .public) tokenLen=\(token.count, privacy: .public)")
        FileLog.note("RpcClient", "connect target=\(host):\(port) tokenLen=\(token.count)")
    }

    func close() {
        log.notice("rpc closing")
        eventsRecvTask?.cancel();  eventsRecvTask  = nil
        eventsHeartbeat?.cancel(); eventsHeartbeat = nil
        eventsTask?.cancel(with: .goingAway, reason: nil); eventsTask = nil
        for (_, ch) in ptys {
            ch.recvTask.cancel()
            ch.heartbeat.cancel()
            ch.task.cancel(with: .goingAway, reason: nil)
        }
        ptys.removeAll()
        sessionID = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // ─────────────────────────── public RPC API ───────────────────────────

    @discardableResult
    func call<P: Encodable>(_ method: String, params: P) async throws -> Data {
        switch method {
        case "session.attach":  return try await doAttach(params: params)
        case "session.detach":  return try await doDetach()
        case "pty.write":       return try await doPtyWrite(params: params)
        case "pty.create":      return try await doPtyCreate(params: params)
        case "pty.kill":        return try await doPtyKill(params: params)
        default:                return try await httpCall(method: method, params: params)
        }
    }

    @discardableResult
    func call(_ method: String) async throws -> Data {
        return try await call(method, params: RpcEmpty())
    }

    func call<P: Encodable, R: Decodable>(_ method: String, params: P, as type: R.Type) async throws -> R {
        let bytes = try await call(method, params: params)
        do {
            return try JSONDecoder().decode(R.self, from: bytes)
        } catch {
            throw RpcError.decode("\(method) result: \(error)")
        }
    }

    func call<R: Decodable>(_ method: String, as type: R.Type) async throws -> R {
        return try await call(method, params: RpcEmpty(), as: type)
    }

    // ─────────────────────────── method handlers ───────────────────────────

    private func doAttach<P: Encodable>(params: P) async throws -> Data {
        // POST /rpc/session.attach. Server returns the AttachResult body
        // and sets X-Motif-Session response header.
        let (body, sid) = try await rawCallWithSession(method: "session.attach", params: params)
        guard let sid else { throw RpcError.transport("session.attach: no X-Motif-Session header") }
        self.sessionID = sid

        // Spin up /events.
        let lastSeq = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let since = (lastSeq?["last_seq"] as? UInt64) ?? 0
        try await openEvents(since: since)

        // Open one /pty/<id> for every PTY already in the session.
        if let dict = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]),
           let ptyList = dict["ptys"] as? [[String: Any]] {
            for p in ptyList {
                if let pid = p["id"] as? String {
                    try? await openPty(ptyID: pid, primary: false)
                }
            }
        }
        return body
    }

    private func doDetach() async throws -> Data {
        // Tear down per-pty + events first so the server-side primary
        // bookkeeping clears as the WSes close.
        for (_, ch) in ptys {
            ch.recvTask.cancel(); ch.heartbeat.cancel()
            ch.task.cancel(with: .goingAway, reason: nil)
        }
        ptys.removeAll()
        eventsRecvTask?.cancel();  eventsRecvTask  = nil
        eventsHeartbeat?.cancel(); eventsHeartbeat = nil
        eventsTask?.cancel(with: .goingAway, reason: nil); eventsTask = nil
        let body = try await httpCall(method: "session.detach", params: RpcEmpty())
        sessionID = nil
        return body
    }

    private func doPtyWrite<P: Encodable>(params: P) async throws -> Data {
        // Decode params to extract pty_id + data, route bytes to that
        // PTY's WS instead of doing an HTTP call.
        let raw   = try JSONEncoder().encode(params)
        guard let obj  = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let pid  = obj["pty_id"] as? String,
              let dataB64 = obj["data"] as? String,
              let data = Data(base64Encoded: dataB64)
        else {
            // Some callers pass `data` as raw [UInt8] not base64; handle that too.
            if let obj  = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let pid  = obj["pty_id"] as? String,
               let arr  = obj["data"] as? [Int] {
                try await ensurePtyOpen(ptyID: pid)
                let bytes = Data(arr.map { UInt8(truncatingIfNeeded: $0) })
                try await sendPtyBytes(ptyID: pid, data: bytes)
                return "{}".data(using: .utf8)!
            }
            throw RpcError.decode("pty.write: missing pty_id / data")
        }
        try await ensurePtyOpen(ptyID: pid)
        try await sendPtyBytes(ptyID: pid, data: data)
        return "{}".data(using: .utf8)!
    }

    private func doPtyCreate<P: Encodable>(params: P) async throws -> Data {
        let body = try await httpCall(method: "pty.create", params: params)
        // Pull the new pty_id out and open its WS as primary.
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let info = obj["info"] as? [String: Any],
           let pid = info["id"] as? String {
            try? await openPty(ptyID: pid, primary: true)
        }
        return body
    }

    private func doPtyKill<P: Encodable>(params: P) async throws -> Data {
        let raw = try JSONEncoder().encode(params)
        let pid = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any])?["pty_id"] as? String
        let body = try await httpCall(method: "pty.kill", params: params)
        if let pid, let ch = ptys.removeValue(forKey: pid) {
            ch.recvTask.cancel(); ch.heartbeat.cancel()
            ch.task.cancel(with: .goingAway, reason: nil)
        }
        return body
    }

    // ─────────────────────────── HTTP plumbing ───────────────────────────

    private func httpCall<P: Encodable>(method: String, params: P) async throws -> Data {
        let (body, _) = try await rawCallWithSession(method: method, params: params)
        return body
    }

    private func rawCallWithSession<P: Encodable>(method: String, params: P) async throws -> (Data, String?) {
        guard let urlSession else { throw RpcError.notConnected }
        guard let url = URL(string: "http://\(host):\(port)/rpc/\(method)") else {
            throw RpcError.transport("bad rpc url for `\(method)`")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sid = sessionID {
            req.setValue(sid, forHTTPHeaderField: "X-Motif-Session")
        }
        req.httpBody = try JSONEncoder().encode(params)
        req.timeoutInterval = 30

        let start = Date()
        let (data, response) = try await urlSession.data(for: req)
        let elapsed = Date().timeIntervalSince(start) * 1000
        guard let http = response as? HTTPURLResponse else {
            throw RpcError.transport("non-HTTP response for `\(method)`")
        }
        let sidHeader = http.value(forHTTPHeaderField: "X-Motif-Session")
        log.info("rpc.done method=\(method, privacy: .public) status=\(http.statusCode, privacy: .public) req_size=\(req.httpBody?.count ?? 0, privacy: .public) resp_size=\(data.count, privacy: .public) total_ms=\(elapsed, privacy: .public)")
        FileLog.note("RpcClient", "rpc.done method=\(method) status=\(http.statusCode) resp=\(data.count) total_ms=\(String(format: "%.1f", elapsed))")
        if !(200...299).contains(http.statusCode) {
            if let err = try? JSONDecoder().decode(RpcErrorPayload.self, from: data) {
                throw RpcError.server(code: err.code, message: err.message)
            }
            throw RpcError.transport("HTTP \(http.statusCode)")
        }
        return (data, sidHeader)
    }

    // ─────────────────────────── /events ───────────────────────────

    private func openEvents(since: UInt64) async throws {
        guard let urlSession, let delegate, let sid = sessionID else { throw RpcError.notConnected }
        guard let url = URL(string: "ws://\(host):\(port)/events?session=\(sid)&since=\(since)") else {
            throw RpcError.transport("bad events url")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: req)
        task.resume()
        try await delegate.waitForOpen()
        self.eventsTask = task
        self.eventsLastRecv = Date()
        self.eventsRecvTask = Task { await self.eventsRecvLoop(task: task) }
        self.eventsHeartbeat = Task { await self.eventsHeartbeatLoop(task: task) }
    }

    private func eventsRecvLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                eventsLastRecv = Date()
                switch msg {
                case .string(let s):
                    if let d = s.data(using: .utf8) { yieldEvent(method: methodOf(d) ?? "?", frame: d) }
                case .data(let d):
                    yieldEvent(method: methodOf(d) ?? "?", frame: d)
                @unknown default: continue
                }
            } catch {
                if Task.isCancelled { return }
                log.error("events recv: \(String(describing: error), privacy: .public)")
                eventContinuation?.finish()
                eventContinuation = nil
                return
            }
        }
    }

    private func eventsHeartbeatLoop(task: URLSessionWebSocketTask) async {
        let tickNs = UInt64(heartbeatTick * 1_000_000_000)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: tickNs)
            if Task.isCancelled { return }
            let idle = Date().timeIntervalSince(eventsLastRecv)
            if idle > idleTimeout {
                log.error("events idle=\(idle, privacy: .public)s; closing")
                task.cancel(with: .goingAway, reason: nil)
                return
            }
            task.sendPing { [weak self] err in
                if err != nil { return }
                Task { await self?.bumpEventsLiveness() }
            }
        }
    }

    private func bumpEventsLiveness() { eventsLastRecv = Date() }

    private func methodOf(_ data: Data) -> String? {
        struct Peek: Decodable { let method: String? }
        return (try? JSONDecoder().decode(Peek.self, from: data))?.method
    }

    private func yieldEvent(method: String, frame: Data) {
        eventContinuation?.yield(Event(method: method, frame: frame))
    }

    // ─────────────────────────── /pty/<id> ───────────────────────────

    private func ensurePtyOpen(ptyID: String) async throws {
        if ptys[ptyID] != nil { return }
        try await openPty(ptyID: ptyID, primary: false)
    }

    private func openPty(ptyID: String, primary: Bool) async throws {
        guard let urlSession, let delegate, let sid = sessionID else { throw RpcError.notConnected }
        guard let url = URL(string: "ws://\(host):\(port)/pty/\(ptyID)?session=\(sid)&since=0&primary=\(primary ? 1 : 0)") else {
            throw RpcError.transport("bad pty url")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = urlSession.webSocketTask(with: req)
        task.resume()
        try await delegate.waitForOpen()

        let recvTask  = Task { await self.ptyRecvLoop(ptyID: ptyID, task: task) }
        let heartbeat = Task { await self.ptyHeartbeatLoop(ptyID: ptyID, task: task) }
        ptys[ptyID] = PtyChannel(
            task: task,
            recvTask: recvTask,
            heartbeat: heartbeat,
            lastRecv: Date(),
            shell: ShellState(),
        )
    }

    private func sendPtyBytes(ptyID: String, data: Data) async throws {
        guard let ch = ptys[ptyID] else { throw RpcError.transport("pty.write: no channel for `\(ptyID)`") }
        try await ch.task.send(.data(data))
    }

    private func ptyRecvLoop(ptyID: String, task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                if var ch = ptys[ptyID] { ch.lastRecv = Date(); ptys[ptyID] = ch }
                let data: Data
                switch msg {
                case .data(let d):
                    data = d
                case .string(let s):
                    data = s.data(using: .utf8) ?? Data()
                @unknown default: continue
                }
                processPtyBytes(ptyID: ptyID, bytes: data)
            } catch {
                if Task.isCancelled { return }
                log.notice("pty `\(ptyID, privacy: .public)` recv: \(String(describing: error), privacy: .public)")
                return
            }
        }
    }

    /// Run an incoming /pty/<id> byte chunk through the per-PTY
    /// shell-integration parser. Emits a synthesized `pty.output`
    /// notification (carrying the active block_id + scope) for any
    /// passthrough bytes, plus one notification per recognized OSC
    /// marker. Matches the legacy wire shape so existing MotifClient
    /// handlers keep working unchanged.
    private func processPtyBytes(ptyID: String, bytes: Data) {
        guard var ch = ptys[ptyID] else { return }
        let (passthrough, events) = ch.shell.feed(bytes)
        let blockID = ch.shell.activeBlockID
        let scope   = ch.shell.activeScope
        ptys[ptyID] = ch

        if !passthrough.isEmpty {
            let frame = synthesizePtyOutputFrame(
                ptyID: ptyID, bytes: passthrough,
                blockID: blockID, scope: scope,
            )
            yieldEvent(method: "pty.output", frame: frame)
        }
        for ev in events {
            let (method, frame) = synthesizeShellEventFrame(ptyID: ptyID, event: ev)
            yieldEvent(method: method, frame: frame)
        }
    }

    private func ptyHeartbeatLoop(ptyID: String, task: URLSessionWebSocketTask) async {
        let tickNs = UInt64(heartbeatTick * 1_000_000_000)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: tickNs)
            if Task.isCancelled { return }
            let idle = Date().timeIntervalSince(ptys[ptyID]?.lastRecv ?? Date())
            if idle > idleTimeout {
                log.error("pty `\(ptyID, privacy: .public)` idle; closing")
                task.cancel(with: .goingAway, reason: nil)
                return
            }
            task.sendPing { [weak self] err in
                if err != nil { return }
                Task { await self?.bumpPtyLiveness(ptyID: ptyID) }
            }
        }
    }

    private func bumpPtyLiveness(ptyID: String) {
        if var ch = ptys[ptyID] { ch.lastRecv = Date(); ptys[ptyID] = ch }
    }

    private func synthesizePtyOutputFrame(
        ptyID: String, bytes: Data,
        blockID: String?, scope: ShellOutputScope,
    ) -> Data {
        // Match the legacy /ws `pty.output` notification shape so
        // existing MotifClient.handleEvent code decodes cleanly.
        // block_id + scope now come from the client-side OSC parser.
        let blockIDValue: Any = blockID.map { $0 as Any } ?? NSNull()
        let payload: [String: Any] = [
            "method": "pty.output",
            "params": [
                "pty_id":   ptyID,
                "data_b64": bytes.base64EncodedString(),
                "block_id": blockIDValue,
                "scope":    scope.rawValue,
                "seq":      0,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// Serialize a high-level `ShellEvent` into the JSON-RPC
    /// Notification shape MotifClient was already consuming from
    /// /events. Returned `method` tells `yieldEvent` how to label the
    /// frame for routing.
    private func synthesizeShellEventFrame(ptyID: String, event: ShellEvent) -> (String, Data) {
        let method: String
        let params: [String: Any]
        switch event {
        case .bootstrapped(let shell):
            method = "pty.shell_bootstrapped"
            params = ["pty_id": ptyID, "shell": shell, "seq": 0]
        case .promptStarted(let id):
            method = "pty.prompt_started"
            params = ["pty_id": ptyID, "block_id": id, "seq": 0]
        case .promptEnded(let id):
            method = "pty.prompt_ended"
            params = ["pty_id": ptyID, "block_id": id, "seq": 0]
        case .commandStarted(let id, let text, let cwd, let at):
            method = "pty.command_started"
            params = [
                "pty_id": ptyID, "block_id": id, "text": text,
                "cwd": cwd, "started_at": at, "seq": 0,
            ]
        case .commandFinished(let id, let exit, let at):
            method = "pty.command_finished"
            var p: [String: Any] = [
                "pty_id": ptyID, "block_id": id,
                "finished_at": at, "seq": 0,
            ]
            if let exit { p["exit_code"] = exit }
            params = p
        case .shellContext(let ctx):
            method = "pty.shell_context"
            params = ["pty_id": ptyID, "ctx": ctx, "seq": 0]
        case .cwdChanged(let cwd):
            method = "pty.cwd_changed"
            params = ["pty_id": ptyID, "cwd": cwd, "seq": 0]
        }
        let frame = (try? JSONSerialization.data(
            withJSONObject: ["method": method, "params": params],
        )) ?? Data()
        return (method, frame)
    }
}
