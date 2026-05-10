import Foundation
import OSLog

/// Top-level ASR coordinator. Handles the full pipeline:
///   AudioCapture (16k mono Int16 PCM) ->
///   re-pack into 320-sample (20 ms) frames ->
///   OpusEncoder ->
///   AsrSession (StartTask / StartSession / TaskRequest / FinishSession) ->
///   partial/final transcripts surfaced to the caller.
///
/// Credentials are obtained via DeviceRegistry on first use and cached in
/// Keychain. Wave handshake support is included for future encrypted RPCs
/// (NER, etc.) but the ASR WS itself uses the plain ASR token.
actor DoubaoASR {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "DoubaoASR")
    private let registry = DeviceRegistry()
    private let audio = AudioCapture()

    private var session: AsrSession?
    private var encoder: OpusEncoder?
    private var pcmBuffer = Data()
    private var frameIndex: Int = 0
    private var pumpTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// Bytes of PCM per 20 ms frame at 16 kHz mono Int16 = 320 samples × 2.
    private static let bytesPerFrame: Int = 320 * 2

    enum Event: Sendable {
        case partial(text: String)
        case final(text: String)
        case error(String)
        case stopped
    }

    /// Begin a recognition session. Returns a stream that yields partial
    /// transcripts (as the model emits them) and a single final result
    /// when the user stops speaking. The stream finishes after `stop()`
    /// or on terminal error.
    func start(appName: String = "com.android.chrome") async throws -> AsyncStream<Event> {
        try await teardownIfNeeded()

        let creds = try await registry.ensureCredentials()
        guard let token = creds.asrToken, !token.isEmpty else {
            throw ASRPipelineError.missingToken
        }

        let session = AsrSession(deviceID: creds.deviceID, asrToken: token, appName: appName)
        self.session = session
        let asrEvents = try await session.start()

        let encoder = try OpusEncoder()
        self.encoder = encoder

        let pcmStream = try await audio.start()

        let (out, cont) = AsyncStream.makeStream(of: Event.self)

        // Forward AsrSession events to the consumer stream.
        eventTask = Task {
            for await ev in asrEvents {
                switch ev {
                case .taskStarted, .sessionStarted: break
                case .partial(let t): cont.yield(.partial(text: t))
                case .final(let t):   cont.yield(.final(text: t))
                case .error(let m):   cont.yield(.error(m)); cont.finish()
                case .sessionFinished: cont.yield(.stopped); cont.finish()
                }
            }
        }

        // Pump PCM → encode → send.
        pumpTask = Task {
            for await chunk in pcmStream {
                await self.feed(pcm: chunk)
            }
            await self.flushAndFinish()
        }

        log.notice("DoubaoASR started")
        return out
    }

    /// Stop capturing audio + flush. The event stream returned from
    /// `start()` will yield the final transcript and then finish.
    func stop() async {
        await audio.stop()        // ends the PCM AsyncStream → pumpTask completes → flushAndFinish runs
    }

    // MARK: - Pipeline

    private func feed(pcm: Data) async {
        pcmBuffer.append(pcm)
        guard let session, let encoder else { return }
        while pcmBuffer.count >= Self.bytesPerFrame {
            let frame = pcmBuffer.prefix(Self.bytesPerFrame)
            pcmBuffer.removeFirst(Self.bytesPerFrame)
            let opus: Data
            do {
                opus = try encoder.encode(frame: Data(frame))
            } catch {
                log.error("opus encode failed: \(String(describing: error), privacy: .public)")
                return
            }
            let state: Asr_FrameState = (frameIndex == 0) ? .first : .middle
            await session.sendFrame(opus: opus, state: state)
            frameIndex += 1
        }
    }

    private func flushAndFinish() async {
        guard let session, let encoder else { return }
        // Pad any remaining bytes up to a full frame (silence) and tag
        // FRAME_STATE_LAST. If we didn't send any frames at all, the LAST
        // marker is on a single silent frame so the server still sees a
        // proper sequence terminator.
        var tail = pcmBuffer
        pcmBuffer.removeAll()
        if tail.count < Self.bytesPerFrame {
            tail.append(Data(repeating: 0, count: Self.bytesPerFrame - tail.count))
        } else if tail.count > Self.bytesPerFrame {
            tail = tail.prefix(Self.bytesPerFrame)
        }
        if let opus = try? encoder.encode(frame: Data(tail)) {
            await session.sendFrame(opus: opus, state: .last)
        }
        await session.finish()
    }

    private func teardownIfNeeded() async throws {
        if let session { await session.close() }
        await audio.stop()
        eventTask?.cancel()
        pumpTask?.cancel()
        session = nil
        encoder = nil
        pcmBuffer.removeAll()
        frameIndex = 0
    }

    enum ASRPipelineError: Error, CustomStringConvertible {
        case missingToken
        var description: String {
            switch self {
            case .missingToken: return "ASR token not available; device registration may have failed"
            }
        }
    }
}
