import AVFoundation
import OSLog

/// Captures microphone audio and emits 16-bit signed LE PCM at 16 kHz mono.
///
/// Doubao's ASR expects exactly that format (320 samples per 20 ms frame).
/// We tap AVAudioEngine's input node at its native format, then convert with
/// AVAudioConverter to the target format. The downstream consumer iterates
/// `frames` (an AsyncStream) and packs into 20 ms frames itself.
actor AudioCapture {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "AudioCapture")

    static let targetSampleRate: Double = 16_000
    static let targetChannels: AVAudioChannelCount = 1

    enum CaptureError: Error, CustomStringConvertible {
        case permissionDenied
        case engineFailed(String)
        case formatUnavailable

        var description: String {
            switch self {
            case .permissionDenied:    return "microphone permission denied"
            case .engineFailed(let m): return "audio engine failed: \(m)"
            case .formatUnavailable:   return "could not create target audio format"
            }
        }
    }

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<Data>.Continuation?

    /// Returns an AsyncStream that yields raw 16-bit LE PCM bytes at 16 kHz
    /// mono. The stream finishes when `stop()` is called or capture errors.
    func start() async throws -> AsyncStream<Data> {
        guard await Self.requestPermission() else {
            throw CaptureError.permissionDenied
        }

        // Configure audio session for record. Allow mixing so background
        // music keeps playing if anything's running.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            throw CaptureError.engineFailed("setCategory: \(error)")
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannels,
            interleaved: true
        ) else {
            throw CaptureError.formatUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.formatUnavailable
        }

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.continuation = continuation
        self.converter = converter
        self.engine = engine

        // Use a tap buffer big enough to hold ~100ms of input audio so the
        // ASR side doesn't see micro-frames. We re-pack into 20ms frames in
        // the consumer (DoubaoASR), not here.
        let tapBufferSize: AVAudioFrameCount = 1024

        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self, log] buffer, _ in
            guard let self else { return }
            // Compute the output capacity needed for the target rate.
            let ratio = Self.targetSampleRate / inputFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)

            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                log.error("failed to allocate converter output buffer")
                return
            }

            var error: NSError?
            var supplied = false
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }

            switch status {
            case .haveData, .inputRanDry:
                if let bytes = Self.toData(int16Buffer: outBuffer) {
                    Task { await self.yield(bytes) }
                }
            case .error:
                log.error("convert error: \(String(describing: error), privacy: .public)")
            case .endOfStream:
                break
            @unknown default:
                break
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            self.continuation = nil
            throw CaptureError.engineFailed("start: \(error)")
        }

        log.notice("AudioCapture started (input \(inputFormat.sampleRate, privacy: .public) Hz / \(inputFormat.channelCount, privacy: .public) ch)")
        return stream
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        continuation?.finish()
        continuation = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            log.warning("setActive(false): \(String(describing: error), privacy: .public)")
        }
        log.notice("AudioCapture stopped")
    }

    private func yield(_ data: Data) {
        continuation?.yield(data)
    }

    // MARK: - Helpers

    private static func toData(int16Buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = int16Buffer.int16ChannelData else { return nil }
        let frameCount = Int(int16Buffer.frameLength)
        let channels = Int(int16Buffer.format.channelCount)
        // Interleaved Int16: a single channel pointer holds frames * channels samples
        // because we constructed the format as interleaved=true.
        let byteCount = frameCount * channels * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }

    private static func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }
}
