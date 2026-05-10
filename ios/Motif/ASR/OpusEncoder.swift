import Foundation
import COpus
import OSLog

/// Wraps libopus's `OpusEncoder` for the format Doubao expects: 16 kHz
/// mono signed-Int16 PCM, encoded as 20 ms frames (320 samples per frame).
/// Each call produces one self-contained Opus packet — no Ogg, no
/// container, just the raw frame bytes the WS protocol takes.
final class OpusEncoder {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "OpusEncoder")

    static let sampleRate: Int32 = 16_000
    static let channels: Int32 = 1
    static let frameSamples: Int32 = 320      // 20 ms at 16 kHz
    static let maxPacketBytes: Int = 1500

    private var encoder: OpaquePointer?

    enum EncoderError: Error, CustomStringConvertible {
        case createFailed(rc: Int32)
        case encodeFailed(rc: Int32)
        case wrongFrameSize(expected: Int, got: Int)

        var description: String {
            switch self {
            case .createFailed(let rc): return "opus_encoder_create returned \(rc)"
            case .encodeFailed(let rc): return "opus_encode returned \(rc)"
            case .wrongFrameSize(let e, let g): return "expected \(e) samples per frame, got \(g)"
            }
        }
    }

    init() throws {
        var err: Int32 = 0
        let enc = opus_encoder_create(Self.sampleRate, Self.channels, OPUS_APPLICATION_AUDIO, &err)
        guard err == OPUS_OK, enc != nil else {
            throw EncoderError.createFailed(rc: err)
        }
        self.encoder = enc
        // Doubao keeps the upstream defaults (no bitrate / complexity / VBR
        // overrides). Match that exactly to keep the wire format identical.
    }

    deinit {
        if let encoder { opus_encoder_destroy(encoder) }
    }

    /// Encode exactly one 20 ms frame (320 Int16 samples) and return the
    /// raw Opus packet bytes.
    func encode(frame pcm: Data) throws -> Data {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount == Int(Self.frameSamples) else {
            throw EncoderError.wrongFrameSize(expected: Int(Self.frameSamples), got: sampleCount)
        }

        guard let encoder else { throw EncoderError.encodeFailed(rc: -100) }
        var output = Data(count: Self.maxPacketBytes)
        let written: Int32 = output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int32 in
            let outBase = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return pcm.withUnsafeBytes { (pcmRaw: UnsafeRawBufferPointer) -> Int32 in
                let pcmBase = pcmRaw.baseAddress!.assumingMemoryBound(to: opus_int16.self)
                return opus_encode(encoder, pcmBase, Self.frameSamples, outBase, Int32(Self.maxPacketBytes))
            }
        }
        guard written > 0 else {
            throw EncoderError.encodeFailed(rc: written)
        }
        output.removeSubrange(Int(written)..<output.count)
        return output
    }
}
