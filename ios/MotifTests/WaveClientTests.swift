import XCTest
@testable import Motif

/// Byte-stability tests for the Wave handshake JSON. The server-side
/// signature check fails on any byte-level divergence from what pydantic
/// emits, so we lock down the field order and formatting here.
final class WaveClientTests: XCTestCase {
    func testHandshakeJSONShape() {
        let randomBytes = Data(repeating: 0xAB, count: 32)
        let pubkey = Data([0x04] + Array(repeating: UInt8(0xCD), count: 64))
        let json = WaveClient.handshakeRequestJSON(
            random: randomBytes,
            appID: "401734",
            did: "1234567890123456789",
            pubkeyBytes: pubkey
        )

        // Must start with {"version":2,"random":" — no spaces, this exact key
        // order — because pydantic v2 emits declaration order without
        // whitespace, and we sign these bytes.
        XCTAssertTrue(json.hasPrefix("{\"version\":2,\"random\":\""), "json prefix wrong: \(json.prefix(60))")

        // Field order: version, random, app_id, did, key_shares, cipher_suites.
        let positions = ["\"version\":", "\"random\":", "\"app_id\":", "\"did\":",
                         "\"key_shares\":", "\"cipher_suites\":"]
            .map { json.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains(where: { $0 == nil }), "missing field in: \(json)")
        for i in 1..<positions.count {
            XCTAssertLessThan(positions[i - 1]!, positions[i]!,
                              "fields out of order in \(json)")
        }

        // No whitespace: spaces, newlines, tabs.
        XCTAssertFalse(json.contains(" "), "json should have no spaces: \(json)")
        XCTAssertFalse(json.contains("\n"))

        // cipher_suites is exactly [4097].
        XCTAssertTrue(json.contains("\"cipher_suites\":[4097]"), "cipher_suites wrong: \(json)")

        // key_shares value shape: [{"curve":"secp256r1","pubkey":"..."}]
        XCTAssertTrue(json.contains("\"key_shares\":[{\"curve\":\"secp256r1\",\"pubkey\":\""))

        // Tail must be `}` with no trailing comma.
        XCTAssertTrue(json.hasSuffix("}"), "json must end with }: \(json.suffix(40))")

        // Roundtrip: must still parse as valid JSON.
        let data = Data(json.utf8)
        let obj = try? JSONSerialization.jsonObject(with: data)
        XCTAssertNotNil(obj, "produced JSON not parseable: \(json)")
    }

    func testHandshakeJSONExactBytes() {
        // Pin one fully concrete fixture so any future refactor of the
        // builder shows up as a one-line diff in the test result.
        let random = Data(base64Encoded: "AAAA////AAAAAAAAAAAA////AAAA////AAAAAAA=")!
        let pub = Data(base64Encoded: "BAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PDw9Pj9A")!
        let json = WaveClient.handshakeRequestJSON(
            random: random,
            appID: "401734",
            did: "987654321",
            pubkeyBytes: pub
        )
        let expected = "{\"version\":2,\"random\":\"\(random.base64EncodedString())\",\"app_id\":\"401734\",\"did\":\"987654321\",\"key_shares\":[{\"curve\":\"secp256r1\",\"pubkey\":\"\(pub.base64EncodedString())\"}],\"cipher_suites\":[4097]}"
        XCTAssertEqual(json, expected)
    }
}
