import Foundation
import OSLog

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
/// Wire envelope for an RPC request. Lifted out of `RpcClient.call` so the
/// generic parameter is allowed (Swift forbids generic structs nested in
/// generic functions).
private struct RpcEnvelope<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: P
}

private struct RpcEmpty: Encodable {}

actor RpcClient {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "RpcClient")

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

    /// A server-pushed notification (no id). `params` is whatever JSON
    /// shape the protocol declares for that method — callers pull fields
    /// out via `JSONDecoder` against a method-specific Codable type.
    struct Event: Sendable {
        let method: String
        let params: Data  // raw JSON; decode lazily per-event-type
    }

    private var task: URLSessionWebSocketTask?
    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<Event>.Continuation?
    let events: AsyncStream<Event>

    init() {
        var cont: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.eventContinuation = cont
    }

    func connect(url: URL) async throws {
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveTask = Task { await self.receiveLoop() }
        log.notice("rpc connected: \(url.absoluteString, privacy: .public)")
    }

    func close() {
        log.notice("rpc closing")
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // Reject every outstanding call.
        for cont in pending.values { cont.resume(throwing: RpcError.transport("closed")) }
        pending.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    /// Make a JSON-RPC request and wait for the matching response.
    @discardableResult
    func call<P: Encodable>(_ method: String, params: P) async throws -> Data {
        guard let task else { throw RpcError.notConnected }
        let id = nextID; nextID += 1

        let body = RpcEnvelope(id: id, method: method, params: params)
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw RpcError.decode("encode: \(error)")
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.pending[id] = cont
            Task { [weak self] in
                do {
                    try await task.send(.string(String(data: data, encoding: .utf8) ?? ""))
                } catch {
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

    /// Convenience: decode the result into a Codable.
    func call<P: Encodable, R: Decodable>(_ method: String, params: P, as type: R.Type) async throws -> R {
        let data = try await call(method, params: params)
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw RpcError.decode("\(method) result: \(error); body=\(String(data: data, encoding: .utf8) ?? "?")")
        }
    }

    func call<R: Decodable>(_ method: String, as type: R.Type) async throws -> R {
        return try await call(method, params: RpcEmpty(), as: type)
    }

    // MARK: - Internals

    private func fail(id: Int, error: Error) {
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
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let s):
                    if let d = s.data(using: .utf8) { handleFrame(d) }
                case .data(let d):
                    handleFrame(d)
                @unknown default: continue
                }
            } catch {
                if Task.isCancelled { return }
                log.error("rpc recv: \(String(describing: error), privacy: .public)")
                // Cascade-reject everything in flight, finish event stream.
                for cont in pending.values { cont.resume(throwing: RpcError.transport("\(error)")) }
                pending.removeAll()
                eventContinuation?.finish()
                eventContinuation = nil
                return
            }
        }
    }

    private func handleFrame(_ data: Data) {
        // Untagged shape: {id, result|error} = response, {method, params} = notification.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("rpc: malformed frame (\(data.count, privacy: .public)B)")
            return
        }

        if let id = obj["id"] as? Int {
            if let err = obj["error"] as? [String: Any] {
                let code = (err["code"] as? Int) ?? -32603
                let msg = (err["message"] as? String) ?? "(no message)"
                fail(id: id, error: RpcError.server(code: code, message: msg))
                return
            }
            // Pull out the `result` sub-object (re-serialize so callers can
            // decode it as their own Codable).
            if let result = obj["result"] {
                if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    deliver(id: id, payload: bytes)
                } else {
                    fail(id: id, error: RpcError.decode("re-encode result"))
                }
            } else {
                deliver(id: id, payload: Data("null".utf8))
            }
            return
        }

        // Notification.
        if let method = obj["method"] as? String {
            let params = obj["params"] ?? [:]
            let bytes = (try? JSONSerialization.data(withJSONObject: params, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
            eventContinuation?.yield(Event(method: method, params: bytes))
            return
        }

        log.error("rpc: frame matches neither response nor notification")
    }
}
