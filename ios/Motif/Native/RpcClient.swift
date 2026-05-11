import Foundation
import MessagePack
import OSLog
import TalkerCommonSync

/// Native JSON-RPC 2.0 client over a single WebSocket. Mirrors what the
/// motif-web JS client does, minus the auth.login first-frame dance —
/// motifd uses Bearer auth on the WS upgrade and the local TailscaleProxy
/// injects that header for us, so we just open the WS and start calling.
///
/// API:
///   - `connect(url:)` → opens the socket, starts the receive loop
///   - `call(method:params:)` → request/response with auto id
///   - `events` → AsyncStream of server-pushed notifications
///   - `close()` → tears everything down
///
/// Wire mode (set at init):
///   - `.json`   — JSON-RPC over WebSocket text frames (legacy).
///   - `.binary` — MessagePack over WebSocket binary frames. The caller
///     must also add `?bin=1` to the connect URL so motifd negotiates
///     into the matching codec.
/// Wire envelope for an RPC request. Lifted out of `RpcClient.call` so the
/// generic parameter is allowed (Swift forbids generic structs nested in
/// generic functions).
private struct RpcEnvelope<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: P
}

private struct RpcEmpty: Encodable, Decodable {}

/// Whole-frame Decodable used by binary mode to extract a typed `result`
/// or `error` from a single MessagePackDecoder pass.
private struct ResponseEnvelope<R: Decodable>: Decodable {
    let id: Int
    let result: R?
    let error: RpcErrorPayload?
}

/// Whole-frame Decodable used by binary mode to extract typed event
/// `params` (e.g. PtyOutputEvent) in one MessagePackDecoder pass.
private struct NotificationEnvelope<P: Decodable>: Decodable {
    let method: String
    let params: P
}

private struct RpcErrorPayload: Decodable {
    let code: Int
    let message: String
}

/// Lightweight peek used by the receive loop to route a frame as either
/// a response (has `id`) or a notification (has `method`, no `id`)
/// without paying for a full typed decode.
private struct FrameDescriptor: Decodable {
    let id: Int?
    let method: String?
}

/// URLSession delegate that captures WebSocket lifecycle events and
/// surfaces them via OSLog. URLSession owns this strongly while it's
/// active, so we don't need to retain it ourselves once it's installed.
final class WSLogDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "RpcClient.ws")

    /// Suspends until either `didOpenWithProtocol` (success) or
    /// `didCompleteWithError` (failure) fires. URLSession's WS task
    /// `resume()` returns immediately — without this gate, callers send
    /// frames into a half-open task and URLSession aborts with -1005
    /// / -1000 / -1001 when the upgrade dance hasn't actually happened
    /// yet. Repeated calls return the cached result.
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

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol proto: String?
    ) {
        log.notice("ws didOpen (protocol=\(proto ?? "(none)", privacy: .public))")
        FileLog.note("ws", "didOpen protocol=\(proto ?? "(none)")")
        resolveOpen(.success(()))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "(none)"
        log.error("ws didClose code=\(closeCode.rawValue, privacy: .public) reason=\(reasonStr, privacy: .public)")
        FileLog.note("ws", "didClose code=\(closeCode.rawValue) reason=\(reasonStr)")
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        // Whether or not the task completed cleanly, anyone waiting for
        // `didOpen` needs to be unblocked: didCompleteWithError replaces
        // didOpen if the task dies before the upgrade.
        if let error {
            resolveOpen(.failure(error))
        } else {
            resolveOpen(.success(()))
        }
        if let error {
            log.error("ws task didComplete error: \(String(describing: error), privacy: .public)")
            // Cracking open the NSError tells us which transport layer
            // actually died: kCFStreamError* maps to the BSD error from
            // the SOCKS5 dial; an underlying NWError shows up here too
            // when the proxy itself rejected. Plain -1005 with no
            // detail = peer RST or motifd not listening; -1003 = host
            // not found; -1004 = connection refused at the proxy hop.
            let ns = error as NSError
            var bits: [String] = []
            bits.append("domain=\(ns.domain)")
            bits.append("code=\(ns.code)")
            if let urlErr = error as? URLError {
                bits.append("urlerr=\(urlErr.code.rawValue)")
                if let host = urlErr.failingURL?.host { bits.append("host=\(host)") }
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                bits.append("under=\(underlying.domain)/\(underlying.code)")
                if let s = underlying.userInfo["NSDescription"] as? String { bits.append("under.desc=\(s)") }
            }
            for k in ["_kCFStreamErrorDomainKey", "_kCFStreamErrorCodeKey",
                      "_NSURLErrorNWPathKey", "_NSURLErrorNWResolutionReportKey",
                      "_NSURLErrorFailingURLSessionTaskErrorKey"] {
                if let v = ns.userInfo[k] {
                    bits.append("\(k)=\(String(describing: v).prefix(180))")
                }
            }
            FileLog.note("ws", "didComplete err " + bits.joined(separator: " "))
        } else {
            log.notice("ws task didComplete (no error)")
            FileLog.note("ws", "didComplete (no error)")
        }
        if let resp = task.response as? HTTPURLResponse {
            log.notice("ws upgrade response: HTTP \(resp.statusCode, privacy: .public); headers=\(resp.allHeaderFields.description, privacy: .public)")
            FileLog.note("ws", "upgrade HTTP \(resp.statusCode); headers=\(resp.allHeaderFields)")
        } else if let r = task.response {
            FileLog.note("ws", "upgrade non-HTTP response: \(r)")
        } else {
            FileLog.note("ws", "no upgrade response on task")
        }
    }
}

actor RpcClient {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "RpcClient")

    /// Negotiated wire codec for the WebSocket. Set at init; both ends
    /// must agree (server side keys off `?bin=1` in the upgrade URL).
    enum WireMode: Sendable {
        case json
        case binary
    }

    enum RpcError: Error, CustomStringConvertible {
        case notConnected
        case decode(String)
        case server(code: Int, message: String)
        case transport(String)

        var description: String {
            switch self {
            case .notConnected:                return "rpc: not connected"
            case .decode(let m):               return "rpc: decode \(m)"
            case .server(let c, let m):        return "rpc \(c): \(m)"
            case .transport(let m):            return "rpc transport: \(m)"
            }
        }
    }

    /// A server-pushed notification (no id). `frame` carries the entire
    /// notification message bytes (JSON or MessagePack); callers pull
    /// typed `params` out via `decode(_:)`, which uses the right decoder
    /// for the active wire mode.
    struct Event: Sendable {
        let method: String
        fileprivate let frame: Data
        fileprivate let mode: WireMode

        /// Decode the notification's `params` into a method-specific
        /// Codable shape. Wraps the typed payload in `NotificationEnvelope`
        /// so we can use a single decoder pass for both wire modes.
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            switch mode {
            case .json:
                return try JSONDecoder().decode(NotificationEnvelope<T>.self, from: frame).params
            case .binary:
                return try MessagePackDecoder().decode(NotificationEnvelope<T>.self, from: frame).params
            }
        }
    }

    let wireMode: WireMode
    private var task: URLSessionWebSocketTask?
    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// Liveness watermark. Bumped by `receiveLoop` on every received frame
    /// AND by the Pong handler in `sendHeartbeatPing`. The heartbeat loop
    /// reads it every tick to decide whether to declare the WS wedged.
    /// URLSessionWebSocketTask silently auto-pongs incoming peer Pings and
    /// does NOT surface them in `receive()`, so without these two write
    /// sites we'd never get a fresh signal once the server falls quiet.
    private var lastRecvAt: Date = Date()
    /// Server-side mirror is 20s/45s; iOS sends its own pings on the same
    /// cadence. 10s tick is the watchdog granularity.
    private let pingInterval: TimeInterval  = 20
    private let idleTimeout:  TimeInterval  = 45
    private let heartbeatTick: TimeInterval = 10
    private var eventContinuation: AsyncStream<Event>.Continuation?
    let events: AsyncStream<Event>

    init(wireMode: WireMode = .json) {
        self.wireMode = wireMode
        var cont: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.eventContinuation = cont
    }

    /// Open a WebSocket. The caller supplies a configured URLSession (so the
    /// caller can route through tsnet's HTTP CONNECT proxy), a URLRequest
    /// with any pre-set headers (Authorization etc), and the URLSession's
    /// `WSLogDelegate` — `connect` only returns once that delegate has
    /// observed `didOpenWithProtocol`. Without that gate, callers race
    /// `task.send(...)` into a half-opened upgrade and URLSession aborts
    /// with -1005/-1000/-1001 while the dance is still in flight.
    func connect(urlSession: URLSession, request: URLRequest, delegate: WSLogDelegate) async throws {
        let headerDigest = (request.allHTTPHeaderFields ?? [:])
            .map { "\($0.key)=\($0.value.prefix(40))" }
            .joined(separator: " | ")
        log.notice("ws.opening \(request.url?.absoluteString ?? "?", privacy: .public) headers={\(headerDigest, privacy: .public)}")
        FileLog.note("RpcClient", "ws.opening \(request.url?.absoluteString ?? "?") headers={\(headerDigest)}")
        if let proxy = urlSession.configuration.proxyConfigurations.first {
            log.notice("ws.proxy=\(String(describing: proxy), privacy: .public)")
        } else {
            log.notice("ws.proxy=(none)")
        }
        let task = urlSession.webSocketTask(with: request)
        self.task = task
        task.resume()
        // Block until the upgrade actually completes. didOpen → success;
        // didCompleteWithError before didOpen → throw, caller surfaces a
        // .failed state instead of the bogus "connected" we used to set.
        try await delegate.waitForOpen()
        lastRecvAt = Date()
        receiveTask  = Task { await self.receiveLoop() }
        heartbeatTask = Task { await self.heartbeatLoop() }
    }

    func close() {
        log.notice("rpc closing")
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // Reject every outstanding call.
        for cont in pending.values { cont.resume(throwing: RpcError.transport("closed")) }
        pending.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    /// Make a JSON-RPC request and wait for the matching response.
    /// Returns the raw frame bytes (whole Response shape) in the active
    /// wire mode — callers that need typed results should use the `as:`
    /// overload below, which is what the rest of the app does.
    @discardableResult
    func call<P: Encodable>(_ method: String, params: P) async throws -> Data {
        guard let task else { throw RpcError.notConnected }
        let id = nextID; nextID += 1

        let body = RpcEnvelope(id: id, method: method, params: params)
        let data: Data
        do {
            data = try encode(body)
        } catch {
            throw RpcError.decode("encode: \(error)")
        }
        let wsMessage: URLSessionWebSocketTask.Message
        switch wireMode {
        case .json:
            wsMessage = .string(String(data: data, encoding: .utf8) ?? "")
        case .binary:
            wsMessage = .data(data)
        }

        log.debug("rpc.send #\(id, privacy: .public) \(method, privacy: .public) (\(data.count, privacy: .public)B mode=\(String(describing: self.wireMode), privacy: .public))")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.pending[id] = cont
            Task { [weak self, log] in
                do {
                    try await task.send(wsMessage)
                } catch {
                    log.error("rpc.send #\(id, privacy: .public) \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    FileLog.note("RpcClient", "send #\(id) \(method) failed: \(error)")
                    if let self {
                        await self.fail(id: id, error: RpcError.transport("send: \(error)"))
                    }
                }
            }
        }
    }

    /// Convenience: call with no params.
    @discardableResult
    func call(_ method: String) async throws -> Data {
        return try await call(method, params: RpcEmpty())
    }

    /// Convenience: decode the result into a Codable. The wire-mode-aware
    /// decoder runs the typed pass via `ResponseEnvelope<R>` so we only
    /// pay one decoder for the whole frame.
    func call<P: Encodable, R: Decodable>(_ method: String, params: P, as type: R.Type) async throws -> R {
        let frame = try await call(method, params: params)
        do {
            let envelope: ResponseEnvelope<R>
            switch wireMode {
            case .json:
                envelope = try JSONDecoder().decode(ResponseEnvelope<R>.self, from: frame)
            case .binary:
                envelope = try MessagePackDecoder().decode(ResponseEnvelope<R>.self, from: frame)
            }
            if let err = envelope.error {
                throw RpcError.server(code: err.code, message: err.message)
            }
            guard let result = envelope.result else {
                throw RpcError.decode("\(method) result: empty")
            }
            return result
        } catch let e as RpcError {
            throw e
        } catch {
            throw RpcError.decode("\(method) result: \(error)")
        }
    }

    func call<R: Decodable>(_ method: String, as type: R.Type) async throws -> R {
        return try await call(method, params: RpcEmpty(), as: type)
    }

    // MARK: - Codec helpers

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        switch wireMode {
        case .json:   return try JSONEncoder().encode(value)
        case .binary: return try MessagePackEncoder().encode(value)
        }
    }

    private func decodeDescriptor(_ data: Data) throws -> FrameDescriptor {
        switch wireMode {
        case .json:   return try JSONDecoder().decode(FrameDescriptor.self, from: data)
        case .binary: return try MessagePackDecoder().decode(FrameDescriptor.self, from: data)
        }
    }

    // MARK: - Internals

    private func fail(id: Int, error: any Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func deliver(id: Int, payload: Data) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(returning: payload)
        } else {
            log.error("response for unknown id=\(id, privacy: .public)")
        }
    }

    private func receiveLoop() async {
        guard let task else { return }
        log.notice("rpc.recvLoop started")
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                // Any frame from the peer means the link is alive.
                // URLSessionWebSocketTask consumes peer Pings internally
                // (auto-Pong) and never surfaces them here, so this site
                // and the Pong handler in sendHeartbeatPing are the only
                // places that can refresh the watermark.
                lastRecvAt = Date()
                switch message {
                case .string(let s):
                    log.debug("rpc.recv text \(s.count, privacy: .public) chars")
                    if let d = s.data(using: .utf8) { handleFrame(d) }
                case .data(let d):
                    log.debug("rpc.recv bin \(d.count, privacy: .public)B")
                    handleFrame(d)
                @unknown default: continue
                }
            } catch {
                if Task.isCancelled { log.notice("rpc.recvLoop cancelled"); return }
                log.error("rpc.recvLoop error: \(String(describing: error), privacy: .public)")
                // Cascade-reject everything in flight, finish event stream.
                for cont in pending.values { cont.resume(throwing: RpcError.transport("\(error)")) }
                pending.removeAll()
                eventContinuation?.finish()
                eventContinuation = nil
                return
            }
        }
        log.notice("rpc.recvLoop exited")
    }

    /// Periodic WS-level liveness: every PING_INTERVAL push a Ping; every
    /// HEARTBEAT_TICK check that the watermark hasn't gone stale.
    /// Without this loop a Mac sleep / wedged-TCP scenario leaves the iOS
    /// app stuck "connected" with no data flowing (URLSession only fires
    /// task errors when the OS gives up on retransmits, which can be
    /// minutes). The Pong handler refreshes the watermark so a healthy
    /// server keeps us alive even during long idle stretches.
    private func heartbeatLoop() async {
        let tickNs       = UInt64(heartbeatTick * 1_000_000_000)
        var nextPingAt   = Date().addingTimeInterval(pingInterval)
        log.notice("rpc.heartbeat started (ping=\(self.pingInterval)s idle=\(self.idleTimeout)s)")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: tickNs)
            if Task.isCancelled { return }
            let now  = Date()
            let idle = now.timeIntervalSince(lastRecvAt)
            if idle > idleTimeout {
                log.error("rpc.heartbeat idle=\(idle, privacy: .public)s > \(self.idleTimeout, privacy: .public)s; closing ws")
                FileLog.note("RpcClient", "ws idle timeout \(Int(idle))s; closing")
                task?.cancel(with: .goingAway, reason: nil)
                return
            }
            if now >= nextPingAt {
                sendHeartbeatPing()
                nextPingAt = now.addingTimeInterval(pingInterval)
            }
        }
    }

    /// Fire one Ping. URLSessionWebSocketTask invokes the handler when
    /// the matching Pong arrives or when the task fails — both refresh
    /// the watermark; failure additionally cancels the task so the
    /// receiveLoop wakes up with an error and the higher-level
    /// MotifClient flips to .failed → triggers reconnect. The handler
    /// runs on URLSession's queue, not the actor's, so we hop back via
    /// `Task { await ... }`.
    private func sendHeartbeatPing() {
        guard let task else { return }
        task.sendPing { [weak self] error in
            guard let self else { return }
            Task { await self.handlePongResult(error: error) }
        }
    }

    private func handlePongResult(error: (any Error)?) async {
        if let error {
            log.error("rpc.heartbeat ping failed: \(String(describing: error), privacy: .public)")
            FileLog.note("RpcClient", "ping failed: \(error)")
            task?.cancel(with: .goingAway, reason: nil)
            return
        }
        lastRecvAt = Date()
    }

    private func handleFrame(_ data: Data) {
        // Peek id/method without paying for a full typed decode. The
        // pending continuation (response path) and the event consumer
        // (notification path) each do their own typed second pass.
        let desc: FrameDescriptor
        do {
            desc = try decodeDescriptor(data)
        } catch {
            log.error("rpc: malformed frame (\(data.count, privacy: .public)B): \(String(describing: error), privacy: .public)")
            return
        }

        if let id = desc.id {
            // Hand the whole frame to the pending call; it owns the
            // typed ResponseEnvelope<R> decode for its R.
            deliver(id: id, payload: data)
            return
        }

        // Notification: hand the whole frame to the event stream; the
        // consumer's `event.decode(_:)` runs a typed
        // NotificationEnvelope<P> pass with the right decoder.
        if let method = desc.method {
            eventContinuation?.yield(Event(method: method, frame: data, mode: wireMode))
            return
        }

        log.error("rpc: frame matches neither response nor notification")
    }
}
