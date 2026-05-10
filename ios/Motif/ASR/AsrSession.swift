import Foundation
import OSLog
import SwiftProtobuf

/// Single Doubao ASR session over a WebSocket. The state machine matches
/// upstream asr.py:
///
///   connect → StartTask → StartSession → N × TaskRequest(FrameState) → FinishSession
///
/// Each AsrRequest is a single protobuf-encoded binary WebSocket message.
/// Responses are AsrResponse protobuf messages containing message_type
/// ("TaskStarted" / "SessionStarted" / "TaskFailed" / etc.) and a JSON
/// `result_json` with intermediate or final transcripts.
actor AsrSession {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "AsrSession")

    /// Result delivered up to the consumer (DoubaoASR / JSBridge).
    enum Event: Sendable {
        case taskStarted
        case sessionStarted
        case partial(text: String)
        case final(text: String)
        case sessionFinished
        case error(String)
    }

    private let deviceID: String
    private let token: String
    private let appName: String  // e.g. "com.android.chrome"
    private let userAgent: String
    private let requestID: String
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var frameIndex: Int = 0
    private var startTimestampMs: Int64 = 0
    private var finished: Bool = false

    init(deviceID: String, asrToken: String,
         appName: String = "com.android.chrome",
         userAgent: String = DoubaoConst.userAgent) {
        self.deviceID = deviceID
        self.token = asrToken
        self.appName = appName
        self.userAgent = userAgent
        self.requestID = UUID().uuidString
    }

    // MARK: - Lifecycle

    /// Connect, send StartTask + StartSession, return a stream of events.
    /// The caller drives audio frames in via `sendFrame(...)`.
    func start() throws -> AsyncStream<Event> {
        guard task == nil else {
            throw AsrError.alreadyStarted
        }

        var components = URLComponents(url: DoubaoConst.websocketURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "aid", value: String(DoubaoConst.aid)),
            URLQueryItem(name: "device_id", value: deviceID)
        ]
        let url = components.url!

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("v2", forHTTPHeaderField: "proto-version")
        request.setValue("true", forHTTPHeaderField: "x-custom-keepalive")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        let (stream, cont) = AsyncStream.makeStream(of: Event.self)
        self.continuation = cont

        // Send the opening pair (StartTask + StartSession) immediately and
        // start the recv loop. Errors during StartTask are surfaced via the
        // event stream, not thrown here.
        Task { await self.kickOff() }
        return stream
    }

    /// Send one Opus-encoded frame. `state` controls the FrameState marker
    /// the server uses to know whether this is the first / middle / last
    /// audio packet of the utterance.
    func sendFrame(opus: Data, state: Asr_FrameState) async {
        guard let task, !finished else { return }
        if startTimestampMs == 0 { startTimestampMs = Self.nowMillis() }

        let timestampMs = startTimestampMs + Int64(frameIndex) * 20
        var req = Asr_AsrRequest()
        req.serviceName = "ASR"
        req.methodName = "TaskRequest"
        req.requestID = requestID
        req.frameState = state
        req.audioData = opus
        let metadata: [String: Any] = ["extra": [String: Any](), "timestamp_ms": timestampMs]
        if let mj = try? JSONSerialization.data(withJSONObject: metadata, options: []),
           let s = String(data: mj, encoding: .utf8) {
            req.payload = s
        }

        if let bytes = try? req.serializedData() {
            try? await task.send(.data(bytes))
        }
        frameIndex += 1
    }

    /// Send FinishSession and let the recv loop drain the closing events.
    /// Idempotent.
    func finish() async {
        guard let task, !finished else { return }
        var req = Asr_AsrRequest()
        req.token = token
        req.serviceName = "ASR"
        req.methodName = "FinishSession"
        req.requestID = requestID
        if let bytes = try? req.serializedData() {
            try? await task.send(.data(bytes))
        }
    }

    /// Hard close — cancels recv loop, closes WS, and emits sessionFinished.
    func close() {
        finished = true
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        continuation?.yield(.sessionFinished)
        continuation?.finish()
        continuation = nil
        task = nil
    }

    // MARK: - Internals

    private func kickOff() async {
        guard let task else { return }
        do {
            // StartTask
            try await task.send(.data(buildHeader(method: "StartTask")))
            // StartSession with audio config payload
            try await task.send(.data(buildHeader(method: "StartSession", payload: sessionConfigJSON())))
            // Start receive loop
            receiveTask = Task { await self.receiveLoop() }
        } catch {
            continuation?.yield(.error("kickoff failed: \(error)"))
            close()
        }
    }

    private func buildHeader(method: String, payload: String? = nil) throws -> Data {
        var req = Asr_AsrRequest()
        req.token = token
        req.serviceName = "ASR"
        req.methodName = method
        req.requestID = requestID
        if let payload { req.payload = payload }
        return try req.serializedData()
    }

    private func sessionConfigJSON() -> String {
        let config: [String: Any] = [
            "audio_info": [
                "channel": 1,
                "format": "speech_opus",
                "sample_rate": 16_000
            ] as [String: Any],
            "enable_punctuation": true,
            "enable_speech_rejection": false,
            "extra": [
                "app_name": appName,
                "cell_compress_rate": 8,
                "did": deviceID,
                "enable_asr_threepass": true,
                "enable_asr_twopass": true,
                "input_mode": "tool"
            ] as [String: Any]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !finished {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    handleIncoming(data: data)
                case .string(let s):
                    if let d = s.data(using: .utf8) { handleIncoming(data: d) }
                @unknown default: break
                }
            } catch {
                if finished { return }
                continuation?.yield(.error("ws recv: \(error)"))
                close()
                return
            }
        }
    }

    private func handleIncoming(data: Data) {
        guard let pb = try? Asr_AsrResponse(serializedBytes: data) else {
            log.error("malformed AsrResponse pb (\(data.count, privacy: .public)B)")
            return
        }
        switch pb.messageType {
        case "TaskStarted":      continuation?.yield(.taskStarted)
        case "SessionStarted":   continuation?.yield(.sessionStarted)
        case "SessionFinished":
            continuation?.yield(.sessionFinished)
            continuation?.finish()
            finished = true
        case "TaskFailed", "SessionFailed":
            continuation?.yield(.error(pb.statusMessage.isEmpty ? "task/session failed" : pb.statusMessage))
            continuation?.finish()
            finished = true
        default:
            // Recognition payload arrives in result_json.
            guard !pb.resultJson.isEmpty,
                  let jsonData = pb.resultJson.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return }

            // No `results` array → heartbeat; ignore (URLSessionWebSocketTask
            // already keeps the conn alive, so we don't need to bump a timer).
            guard let results = obj["results"] as? [[String: Any]] else { return }

            // Find the most relevant text + interim flag.
            var text = ""
            var isInterim = true
            var vadFinished = false
            var nonstream = false
            for r in results {
                if let t = r["text"] as? String, !t.isEmpty { text = t }
                if let interim = r["is_interim"] as? Bool, !interim { isInterim = false }
                if let vf = r["is_vad_finished"] as? Bool, vf { vadFinished = true }
                if let extra = r["extra"] as? [String: Any],
                   let ns = extra["nonstream_result"] as? Bool, ns { nonstream = true }
            }
            if nonstream || (!isInterim && vadFinished) {
                continuation?.yield(.final(text: text))
            } else if !text.isEmpty {
                continuation?.yield(.partial(text: text))
            }
        }
    }

    // MARK: - Helpers

    private static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    enum AsrError: Error, CustomStringConvertible {
        case alreadyStarted
        var description: String {
            switch self {
            case .alreadyStarted: return "AsrSession already started"
            }
        }
    }
}
