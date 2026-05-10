import Foundation

/// RFC 8439 ChaCha20 raw stream cipher (no Poly1305).
///
/// CryptoKit only ships ChaChaPoly (the AEAD form), but Doubao's Wave
/// transport uses the bare stream cipher with a ciphertext MD5 as the
/// integrity check. So we implement RFC 8439 §2.4 directly.
///
/// API: `ChaCha20.apply(key:nonce:counter:to:)` — XORs the keystream onto
/// the input. Encrypt and decrypt are the same operation.
enum ChaCha20 {
    /// - Parameters:
    ///   - key: 32 bytes
    ///   - nonce: 12 bytes (RFC 8439 form)
    ///   - counter: starting block counter (default 0; Doubao starts at 0)
    ///   - input: plaintext or ciphertext
    /// - Returns: the XOR result, same length as `input`.
    static func apply(key: Data, nonce: Data, counter: UInt32 = 0, to input: Data) -> Data {
        precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
        precondition(nonce.count == 12, "ChaCha20 nonce must be 12 bytes")

        var output = Data(count: input.count)
        let keyWords = readLittleEndianWords(key, count: 8)
        let nonceWords = readLittleEndianWords(nonce, count: 3)

        // RFC 8439 §2.3 initial state:
        // c0..c3 : "expand 32-byte k"
        // c4..c11: key (8 words)
        // c12    : counter
        // c13..15: nonce (3 words)
        let constants: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

        var counter = counter
        var offset = 0
        let total = input.count

        while offset < total {
            var state = [UInt32]()
            state.reserveCapacity(16)
            state.append(contentsOf: constants)
            state.append(contentsOf: keyWords)
            state.append(counter)
            state.append(contentsOf: nonceWords)

            let block = chachaBlock(state: state)
            let chunk = min(64, total - offset)

            input.withUnsafeBytes { (rin: UnsafeRawBufferPointer) in
                output.withUnsafeMutableBytes { (rout: UnsafeMutableRawBufferPointer) in
                    let inB = rin.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
                    let outB = rout.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
                    for i in 0..<chunk {
                        let w = block[i / 4]
                        let byte = UInt8((w >> UInt32(8 * (i & 3))) & 0xff)
                        outB[i] = inB[i] ^ byte
                    }
                }
            }

            offset += chunk
            counter &+= 1
        }
        return output
    }

    // MARK: - Internals

    private static func readLittleEndianWords(_ d: Data, count: Int) -> [UInt32] {
        var words = [UInt32]()
        words.reserveCapacity(count)
        d.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<count {
                let p = base.advanced(by: i * 4)
                let w = UInt32(p[0])
                    | (UInt32(p[1]) << 8)
                    | (UInt32(p[2]) << 16)
                    | (UInt32(p[3]) << 24)
                words.append(w)
            }
        }
        return words
    }

    /// One ChaCha20 block. Returns 16 little-endian-packed u32s of keystream.
    private static func chachaBlock(state: [UInt32]) -> [UInt32] {
        var x = state
        // 10 double-rounds = 20 rounds.
        for _ in 0..<10 {
            quarterRound(&x, 0, 4, 8, 12)
            quarterRound(&x, 1, 5, 9, 13)
            quarterRound(&x, 2, 6, 10, 14)
            quarterRound(&x, 3, 7, 11, 15)
            quarterRound(&x, 0, 5, 10, 15)
            quarterRound(&x, 1, 6, 11, 12)
            quarterRound(&x, 2, 7, 8, 13)
            quarterRound(&x, 3, 4, 9, 14)
        }
        for i in 0..<16 { x[i] &+= state[i] }
        return x
    }

    @inline(__always)
    private static func rotateLeft(_ v: UInt32, _ n: UInt32) -> UInt32 {
        return (v &<< n) | (v &>> (32 &- n))
    }

    @inline(__always)
    private static func quarterRound(_ x: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        x[a] &+= x[b]; x[d] = rotateLeft(x[d] ^ x[a], 16)
        x[c] &+= x[d]; x[b] = rotateLeft(x[b] ^ x[c], 12)
        x[a] &+= x[b]; x[d] = rotateLeft(x[d] ^ x[a], 8)
        x[c] &+= x[d]; x[b] = rotateLeft(x[b] ^ x[c], 7)
    }
}
