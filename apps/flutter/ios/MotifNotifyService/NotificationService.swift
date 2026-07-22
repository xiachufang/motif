// Notification Service Extension: decrypts E2E push payloads on-device before
// display — the only hook that runs between APNs delivery and the banner when
// the app is backgrounded/killed. Mirrors the iOS Motif app's MotifNotifyService
// and matches motifd's scheme (crates/motif-server/src/relay.rs):
//   AES-256-GCM, e = base64(ciphertext‖16-byte tag), n = base64(12-byte nonce),
//   key = base64(32 bytes) read from the shared App Group container.
//
// SETUP (needs Xcode, can't be done from Dart alone):
//   1. Add a "Notification Service Extension" target named MotifNotifyService.
//   2. Give the app + extension the SAME App Group (e.g. group.io.allsunday.motif)
//      so both can read the per-device AES key file.
//   3. The Flutter app must mirror PushSettingsStore.encKeyBase64 into that
//      App Group container. Until then this falls back to showing the encrypted
//      stub.
import UserNotifications
import CryptoKit
import Security

final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  // Keep in sync with the Flutter app.
  private let appGroup = "group.io.allsunday.motif"
  private let keyFileName = "motif-push-enc-key"
  private let keyAccount = "motif.push.encKey"

  override func didReceive(_ request: UNNotificationRequest,
                           withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    self.contentHandler = contentHandler
    let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
    self.bestAttempt = content
    guard let content else { contentHandler(request.content); return }

    let info = request.content.userInfo
    guard let eB64 = info["e"] as? String,
          let nB64 = info["n"] as? String,
          let keyB64 = loadKeyBase64(),
          let plaintext = decrypt(keyB64: keyB64, eB64: eB64, nB64: nB64),
          let obj = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
    else {
      // Couldn't decrypt — show whatever the (non-secret) stub carried.
      contentHandler(content)
      return
    }

    if let title = obj["title"] as? String { content.title = title }
    if let body = obj["body"] as? String { content.body = body }
    let motif = obj["motif"] as? [String: Any]
    if let session = (motif?["session_id"] as? String) ?? (obj["session"] as? String) {
      content.userInfo["session"] = session
    }
    if let instanceId = motif?["instance_id"] as? String {
      content.userInfo["instance_id"] = instanceId
    }
    if let viewId = motif?["view_id"] as? String {
      content.userInfo["view_id"] = viewId
    }
    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    if let h = contentHandler, let c = bestAttempt { h(c) }
  }

  /// AES-256-GCM open: sealed box = nonce ‖ ciphertext ‖ tag, where `e` is
  /// ciphertext‖tag (last 16 bytes are the tag) and `n` is the 12-byte nonce.
  private func decrypt(keyB64: String, eB64: String, nB64: String) -> Data? {
    guard let key = Data(base64Encoded: keyB64),
          let eAndTag = Data(base64Encoded: eB64),
          let nonceData = Data(base64Encoded: nB64),
          key.count == 32, eAndTag.count >= 16 else { return nil }
    let ct = eAndTag.prefix(eAndTag.count - 16)
    let tag = eAndTag.suffix(16)
    do {
      let nonce = try AES.GCM.Nonce(data: nonceData)
      let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
      return try AES.GCM.open(box, using: SymmetricKey(data: key))
    } catch {
      return nil
    }
  }

  private func loadKeyBase64() -> String? {
    if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
      let url = dir.appendingPathComponent(keyFileName, isDirectory: false)
      if let data = try? Data(contentsOf: url),
         let key = String(data: data, encoding: .utf8),
         !key.isEmpty {
        return key
      }
    }

    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: keyAccount,
      kSecAttrAccessGroup as String: appGroup,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
          let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
