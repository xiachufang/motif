import Foundation
import CryptoKit
import CommonCrypto

/// Convenience helpers for the Wave transport's crypto needs.
///
/// All primitives are off-the-shelf except ChaCha20 (see `ChaCha20.swift`).
enum Crypto {
    // MARK: - HKDF-SHA256

    /// HKDF-SHA256 with explicit salt and info (full extract+expand). Doubao
    /// uses this with salt = client_random ‖ server_random and the hardcoded
    /// info string "4e30514609050cd3".
    static func hkdfSHA256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let symmKey = SymmetricKey(data: ikm)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: symmKey,
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: - SHA-256 / MD5

    static func sha256(_ data: Data) -> Data {
        let h = SHA256.hash(data: data)
        return Data(h)
    }

    /// Doubao's `x-ss-stub` is the *uppercase hex* MD5 of the request body /
    /// ciphertext. Standalone helper since we need the exact uppercase form.
    static func md5HexUppercased(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - P-256

extension Crypto {
    /// Wraps a single ECDH P-256 key pair used for both key agreement and
    /// ECDSA signing of the handshake JSON. Doubao re-uses the keypair for
    /// both — that's idiomatic per their wave protocol.
    struct P256KeyPair {
        let agreementPrivate: P256.KeyAgreement.PrivateKey
        let signingPrivate: P256.Signing.PrivateKey

        init() {
            let ag = P256.KeyAgreement.PrivateKey()
            self.agreementPrivate = ag
            // Derive a Signing key from the same raw representation so both
            // halves see the same private scalar.
            self.signingPrivate = try! P256.Signing.PrivateKey(rawRepresentation: ag.rawRepresentation)
        }

        /// 65-byte uncompressed SEC1 form: 0x04 ‖ X(32) ‖ Y(32). This is
        /// what Doubao's handshake JSON expects (then base64'd).
        var uncompressedPublic: Data {
            return agreementPrivate.publicKey.x963Representation
        }
    }

    /// ECDSA-SHA256 over `payload`, returned as DER-encoded `Sequence(r, s)`.
    /// CryptoKit's `ECDSASignature.derRepresentation` is exactly that.
    static func ecdsaSignDER(_ payload: Data, with key: P256.Signing.PrivateKey) throws -> Data {
        let sig = try key.signature(for: payload)
        return sig.derRepresentation
    }

    /// Compute the ECDH shared secret as the X-coordinate of (priv * peerPub).
    /// Returns the raw 32-byte X coordinate (no key derivation — Doubao
    /// feeds this into HKDF separately).
    static func ecdhSharedSecret(
        priv: P256.KeyAgreement.PrivateKey,
        peerUncompressed: Data
    ) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerUncompressed)
        let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
        return shared.withUnsafeBytes { Data($0) }
    }
}
