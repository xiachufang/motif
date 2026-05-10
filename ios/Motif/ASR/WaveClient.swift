import Foundation
import CryptoKit
import OSLog

/// ByteDance "Wave" handshake + encrypted request transport.
///
/// Faithful Swift port of the upstream Python `WaveClient`. The fragile bits:
///   - The handshake JSON is hand-constructed in a fixed field order without
///     whitespace, because the body bytes are what we sign with ECDSA. Any
///     reordering or pretty-printing breaks the signature.
///   - We sign with the same P-256 private key used for the ECDH agreement.
///   - ChaCha20 is the raw-stream form (RFC 8439 with counter=0). CryptoKit
///     ChaChaPoly is AEAD and would change the byte layout, so we use our
///     hand-rolled `ChaCha20.apply(...)`.
///   - `x-ss-stub` is the *uppercase* hex MD5 of the ciphertext.
actor WaveClient {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "Wave")
    private let deviceID: String
    private let appID: String
    private(set) var session: Session?
    private let onSessionUpdate: (@Sendable (Session) -> Void)?

    init(deviceID: String, appID: String, session: Session? = nil,
         onSessionUpdate: (@Sendable (Session) -> Void)? = nil) {
        self.deviceID = deviceID
        self.appID = appID
        self.session = session
        self.onSessionUpdate = onSessionUpdate
    }

    struct Session: Codable, Sendable, Equatable {
        var ticket: String
        var ticketLong: String
        var encryptionKey: Data
        var clientRandom: Data
        var serverRandom: Data
        var sharedKey: Data
        var ticketExp: Int
        var ticketLongExp: Int
        var expiresAt: Double  // unix seconds

        var isExpired: Bool { Date().timeIntervalSince1970 >= expiresAt }
    }

    /// Perform a fresh handshake and stash the resulting session.
    func handshake() async throws {
        let kp = Crypto.P256KeyPair()
        let clientRandom = Self.randomBytes(32)
        let pubkeyBytes = kp.uncompressedPublic // 65 B uncompressed SEC1

        // Build the request JSON in the EXACT field order pydantic v2 emits
        // (declaration order, no whitespace). The bytes we POST are the bytes
        // we sign — any divergence here breaks ECDSA verification.
        let bodyJSON = Self.handshakeRequestJSON(
            random: clientRandom,
            appID: appID,
            did: deviceID,
            pubkeyBytes: pubkeyBytes
        )
        let bodyData = Data(bodyJSON.utf8)

        let signatureDER = try Crypto.ecdsaSignDER(bodyData, with: kp.signingPrivate)

        var req = URLRequest(url: DoubaoConst.handshakeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(signatureDER.base64EncodedString(), forHTTPHeaderField: "x-tt-s-sign")
        req.setValue(DoubaoConst.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WaveError.handshakeBadStatus(code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                                                body: String(data: data, encoding: .utf8) ?? "")
        }

        let resp = try JSONDecoder().decode(HandshakeResponse.self, from: data)
        guard let serverRandom = Data(base64Encoded: resp.random),
              let serverPubkey = Data(base64Encoded: resp.key_share.pubkey)
        else {
            throw WaveError.handshakeMalformed
        }
        let shared = try Crypto.ecdhSharedSecret(priv: kp.agreementPrivate, peerUncompressed: serverPubkey)

        // HKDF salt = client_random ‖ server_random; info is the literal
        // hardcoded byte string from the upstream client.
        let salt = clientRandom + serverRandom
        let key = Crypto.hkdfSHA256(ikm: shared, salt: salt, info: DoubaoConst.hkdfInfo, length: 32)

        let now = Date().timeIntervalSince1970
        let session = Session(
            ticket: resp.ticket,
            ticketLong: resp.ticket_long,
            encryptionKey: key,
            clientRandom: clientRandom,
            serverRandom: serverRandom,
            sharedKey: shared,
            ticketExp: resp.ticket_exp,
            ticketLongExp: resp.ticket_long_exp,
            expiresAt: now + Double(resp.ticket_exp) - 60
        )
        self.session = session
        onSessionUpdate?(session)
        log.notice("Wave handshake ok (ticket exp \(resp.ticket_exp)s)")
    }

    /// Encrypt `plaintext` and produce the headers for an encrypted POST.
    /// Refreshes the session automatically if expired.
    func prepareRequest(plaintext: Data, extraHeaders: [String: String] = [:])
        async throws -> (ciphertext: Data, headers: [String: String])
    {
        try await ensureSession()
        guard let s = session else { throw WaveError.noSession }

        let nonce = Self.randomBytes(12)
        let ciphertext = ChaCha20.apply(key: s.encryptionKey, nonce: nonce, counter: 0, to: plaintext)
        let stub = Crypto.md5HexUppercased(ciphertext)

        var h: [String: String] = [
            "Content-Type": "application/json",
            "x-tt-e-b": "1",
            "x-tt-e-t": s.ticket,
            "x-tt-e-p": nonce.base64EncodedString(),
            "x-ss-stub": stub
        ]
        for (k, v) in extraHeaders { h[k] = v }
        return (ciphertext, h)
    }

    /// Decrypt a ciphertext+nonce pair using the active session key.
    func decrypt(ciphertext: Data, nonce: Data) throws -> Data {
        guard let s = session else { throw WaveError.noSession }
        return ChaCha20.apply(key: s.encryptionKey, nonce: nonce, counter: 0, to: ciphertext)
    }

    private func ensureSession() async throws {
        if let s = session, !s.isExpired { return }
        try await handshake()
    }

    // MARK: - Request body shape

    /// Hand-craft the handshake JSON matching pydantic's serialize-by-alias
    /// output: field order = declaration order, no whitespace, ASCII-safe.
    /// This must produce the exact same bytes the server signature check
    /// expects.
    static func handshakeRequestJSON(
        random: Data,
        appID: String,
        did: String,
        pubkeyBytes: Data
    ) -> String {
        // version, random, app_id, did, key_shares, cipher_suites
        var out = "{"
        out += "\"version\":2,"
        out += "\"random\":\"\(random.base64EncodedString())\","
        out += "\"app_id\":\"\(escape(appID))\","
        out += "\"did\":\"\(escape(did))\","
        out += "\"key_shares\":[{\"curve\":\"secp256r1\",\"pubkey\":\"\(pubkeyBytes.base64EncodedString())\"}],"
        out += "\"cipher_suites\":[4097]"
        out += "}"
        return out
    }

    private static func escape(_ s: String) -> String {
        // Doubao's app_id is "401734" and did is a numeric device id; neither
        // contains any character that needs JSON escaping. We still escape
        // backslashes and quotes defensively for future flexibility.
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }

    private static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes)
    }

    // MARK: - Server response

    private struct HandshakeResponse: Decodable {
        let version: Int
        let random: String
        let key_share: KeyShare
        let cipher_suite: Int
        let cert: String
        let ticket: String
        let ticket_exp: Int
        let ticket_long: String
        let ticket_long_exp: Int

        struct KeyShare: Decodable {
            let curve: String
            let pubkey: String
        }
    }

    enum WaveError: Error, CustomStringConvertible {
        case handshakeBadStatus(code: Int, body: String)
        case handshakeMalformed
        case noSession

        var description: String {
            switch self {
            case .handshakeBadStatus(let code, let body):
                return "wave handshake HTTP \(code): \(body.prefix(200))"
            case .handshakeMalformed:  return "wave handshake response malformed"
            case .noSession:           return "no wave session (call handshake first)"
            }
        }
    }
}
