import UserNotifications
import CryptoKit
import Foundation

// Notification Service Extension — decrypts E2E-encrypted push payloads on
// device. The relay delivers ciphertext only; this rewrites the visible
// notification with the decrypted title/body before it's shown.
//
// APNs payload shape (built by the relay from motifd's encrypted blob):
//   {
//     "aps": { "alert": { "body": "🔒 New notification" }, "mutable-content": 1, "sound": "default" },
//     "e": "<base64 ciphertext||tag>",
//     "n": "<base64 12-byte nonce>"
//   }
//
// The decryption key is the per-device AES-256-GCM key the app generated and
// stored in the shared App Group keychain (see PushManager). This file must be
// a member of the MotifNotifyService extension target, which shares the same
// keychain access group.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    // Keep in sync with PushConfig in the app target. Uses the App Group id as
    // the keychain access group (the dedicated keychain-sharing group was
    // refused at runtime with -34018; the App Group is honored reliably).
    private static let keychainGroup = "group.io.allsunday.motif"
    private static let encKeyAccount = "motif.push.enckey"

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let best = (request.content.mutableCopy() as? UNMutableNotificationContent)
        self.bestAttempt = best

        guard let best else { contentHandler(request.content); return }
        let info = request.content.userInfo
        guard
            let eB64 = info["e"] as? String,
            let nB64 = info["n"] as? String,
            let ct = Data(base64Encoded: eB64),
            let nonceData = Data(base64Encoded: nB64),
            let keyData = keychainKey(),
            ct.count > 16
        else {
            // Can't decrypt → leave the placeholder ("🔒 New notification").
            contentHandler(best)
            return
        }

        do {
            let key = SymmetricKey(data: keyData)
            // Wire layout: ciphertext || 16-byte GCM tag.
            let tag = ct.suffix(16)
            let cipher = ct.prefix(ct.count - 16)
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonceData),
                ciphertext: cipher,
                tag: tag
            )
            let plain = try AES.GCM.open(box, using: key)
            if let payload = try? JSONDecoder().decode(DecryptedPayload.self, from: plain) {
                best.title = payload.title
                best.body = payload.body
                if let motif = payload.motif {
                    var u = best.userInfo
                    u["motif"] = [
                        "instance_id": motif.instance_id as Any,
                        "session_id": motif.session_id as Any,
                        "kind": motif.kind as Any,
                    ]
                    best.userInfo = u
                }
            }
        } catch {
            // Leave the placeholder on any failure.
        }
        contentHandler(best)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let best = bestAttempt {
            handler(best)
        }
    }

    private func keychainKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.encKeyAccount,
            kSecAttrAccessGroup as String: Self.keychainGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

private struct DecryptedPayload: Decodable {
    var title: String
    var body: String
    var motif: Motif?
    struct Motif: Decodable {
        var instance_id: String?
        var session_id: String?
        var kind: String?
    }
}
