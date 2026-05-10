import XCTest
@testable import Motif

final class ChaCha20Tests: XCTestCase {
    // RFC 8439 §2.4.2 – Test Vector for the ChaCha20 Cipher
    func testRFC8439Section24Vector() {
        let key = Data((0...31).map { UInt8($0) })
        // counter=1, nonce=00000000:000000004a:00000000
        let nonce = Data([0x00, 0x00, 0x00, 0x00,
                          0x00, 0x00, 0x00, 0x4a,
                          0x00, 0x00, 0x00, 0x00])
        let plaintext = Data("""
        Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.
        """.utf8)
        let expectedHex = """
        6e2e359a2568f98041ba0728dd0d6981
        e97e7aec1d4360c20a27afccfd9fae0b
        f91b65c5524733ab8f593dabcd62b357
        1639d624e65152ab8f530c359f0861d8
        07ca0dbf500d6a6156a38e088a22b65e
        52bc514d16ccf806818ce91ab7793736
        5af90bbf74a35be6b40b8eedf2785e42
        874d
        """.replacingOccurrences(of: "\n", with: "")

        let out = ChaCha20.apply(key: key, nonce: nonce, counter: 1, to: plaintext)
        XCTAssertEqual(hex(out), expectedHex)
    }

    // RFC 8439 §A.2 – Test Vector #2 (counter=0, all-zero nonce, all-zero key)
    func testAllZeroBlock() {
        let key = Data(repeating: 0, count: 32)
        let nonce = Data(repeating: 0, count: 12)
        let pt = Data(repeating: 0, count: 64)
        let expectedHex = """
        76b8e0ada0f13d90405d6ae55386bd28
        bdd219b8a08ded1aa836efcc8b770dc7
        da41597c5157488d7724e03fb8d84a37
        6a43b8f41518a11cc387b669b2ee6586
        """.replacingOccurrences(of: "\n", with: "")
        let out = ChaCha20.apply(key: key, nonce: nonce, counter: 0, to: pt)
        XCTAssertEqual(hex(out), expectedHex)
    }

    // Round-trip: apply twice with same key/nonce/counter should recover input.
    func testInvolution() {
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let plaintext = Data((0..<199).map { _ in UInt8.random(in: 0...255) })
        let ct = ChaCha20.apply(key: key, nonce: nonce, to: plaintext)
        let pt2 = ChaCha20.apply(key: key, nonce: nonce, to: ct)
        XCTAssertEqual(plaintext, pt2)
    }

    // MARK: - helpers

    private func hex(_ d: Data) -> String {
        return d.map { String(format: "%02x", $0) }.joined()
    }
}

final class CryptoTests: XCTestCase {
    func testMD5UppercaseHex() {
        // RFC 1321 test vector: MD5("") = D41D8CD98F00B204E9800998ECF8427E
        XCTAssertEqual(Crypto.md5HexUppercased(Data()), "D41D8CD98F00B204E9800998ECF8427E")
        // MD5("body=null") used by Doubao for the asr-token call.
        let stub = Crypto.md5HexUppercased(Data("body=null".utf8))
        XCTAssertEqual(stub.count, 32)
        XCTAssertEqual(stub.uppercased(), stub) // confirm uppercase
    }

    func testHKDFLengthAndDeterminism() {
        let ikm = Data(repeating: 0xab, count: 32)
        let salt = Data(repeating: 0xcd, count: 64)
        let info = Data("4e30514609050cd3".utf8)
        let a = Crypto.hkdfSHA256(ikm: ikm, salt: salt, info: info, length: 32)
        let b = Crypto.hkdfSHA256(ikm: ikm, salt: salt, info: info, length: 32)
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(a, b)
    }

    func testECDSARoundtripDER() throws {
        let kp = Crypto.P256KeyPair()
        let payload = Data("hello, doubao".utf8)
        let der = try Crypto.ecdsaSignDER(payload, with: kp.signingPrivate)
        // DER ECDSA sig is `30 LL 02 LL r 02 LL s` — first byte must be 0x30.
        XCTAssertEqual(der.first, 0x30)
        // Verify via CryptoKit (round-trip).
        let sig = try P256.Signing.ECDSASignature(derRepresentation: der)
        XCTAssertTrue(kp.signingPrivate.publicKey.isValidSignature(sig, for: payload))
    }

    func testECDHSharedX() throws {
        let a = Crypto.P256KeyPair()
        let b = Crypto.P256KeyPair()
        let shared1 = try Crypto.ecdhSharedSecret(priv: a.agreementPrivate, peerUncompressed: b.uncompressedPublic)
        let shared2 = try Crypto.ecdhSharedSecret(priv: b.agreementPrivate, peerUncompressed: a.uncompressedPublic)
        XCTAssertEqual(shared1.count, 32)
        XCTAssertEqual(shared1, shared2)
    }

    func testUncompressedPublicShape() {
        let kp = Crypto.P256KeyPair()
        let pub = kp.uncompressedPublic
        XCTAssertEqual(pub.count, 65)
        XCTAssertEqual(pub.first, 0x04)
    }
}

import CryptoKit
