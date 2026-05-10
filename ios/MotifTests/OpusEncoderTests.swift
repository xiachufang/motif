import XCTest
@testable import Motif

/// Doubao expects 16 kHz mono 320-sample frames. We can't validate the
/// exact bytes against a fixture (encoder output varies with SIMD paths
/// and minor lib versions), but we can lock the contract: encoding a
/// silent frame returns a small non-empty packet, and bad frame sizes
/// throw.
final class OpusEncoderTests: XCTestCase {
    func testSilentFrameProducesPacket() throws {
        let enc = try OpusEncoder()
        let silence = Data(count: 320 * MemoryLayout<Int16>.size) // 320 zero samples
        let packet = try enc.encode(frame: silence)
        XCTAssertGreaterThan(packet.count, 0)
        XCTAssertLessThan(packet.count, 1500)
    }

    func testWrongSampleCountThrows() throws {
        let enc = try OpusEncoder()
        // 200 samples instead of 320.
        let bad = Data(count: 200 * MemoryLayout<Int16>.size)
        XCTAssertThrowsError(try enc.encode(frame: bad))
    }

    func testEncodeMultipleFramesGivesIndependentPackets() throws {
        let enc = try OpusEncoder()
        // First frame: silence; second frame: a sine-ish ramp.
        let silence = Data(count: 320 * MemoryLayout<Int16>.size)
        let pkt1 = try enc.encode(frame: silence)

        var ramp = [Int16](repeating: 0, count: 320)
        for i in 0..<320 { ramp[i] = Int16(i * 100) }
        let rampData = ramp.withUnsafeBufferPointer { Data(buffer: $0) }
        let pkt2 = try enc.encode(frame: rampData)

        XCTAssertGreaterThan(pkt1.count, 0)
        XCTAssertGreaterThan(pkt2.count, 0)
        // They should differ — silence and a ramp encode to different
        // packets even at the same encoder state.
        XCTAssertNotEqual(pkt1, pkt2)
    }
}
