import Foundation
import UIKit
import UserNotifications
import CryptoKit
import OSLog
import TalkerCommonLogging

// Push notifications (APNs) — registration, per-device E2E key management,
// foreground presentation, and tap deep-linking.
//
// Design (see the push plan):
//   • The .p8 APNs signing key lives ONLY on the author-operated relay; this
//     app holds no push secret. It obtains an opaque APNs device token at
//     runtime and uploads it (plus a per-device AES-256-GCM key) to its motifd
//     via `device.register`.
//   • Notification content is encrypted by motifd with that key; the relay
//     forwards only ciphertext; the Notification Service Extension
//     (MotifNotifyService) decrypts on device. The key is shared with the
//     extension through the App Group keychain access group.
//
// WIRING (not yet done — needs Xcode): add this file + MotifClient+Device.swift
// to the Motif target; add the @UIApplicationDelegateAdaptor in MotifApp;
// enable Push Notifications + App Groups capabilities; set PUSH_KEYCHAIN_GROUP /
// APP_GROUP below to your real identifiers; and call
// `PushManager.shared.registerIfPossible(client:)` after a successful connect.
enum PushConfig {
    /// Keychain access group shared between the app and the extension.
    ///
    /// We use the **App Group** id, not a dedicated `keychain-access-groups`
    /// group: on iOS the system treats every App Group in
    /// `com.apple.security.application-groups` as one of your keychain access
    /// groups, and that entitlement is reliably honored at runtime here.
    /// A dedicated keychain-sharing group (`io.allsunday.motif.push`) was
    /// signed into both binaries but securityd refused it at runtime
    /// (errSecMissingEntitlement -34018) — the App Group sidesteps that.
    static let keychainGroup = "group.io.allsunday.motif"
    /// Keychain account holding the base64 AES-256-GCM key.
    static let encKeyAccount = "motif.push.enckey"
}

@MainActor
final class PushManager: NSObject {
    static let shared = PushManager()

    private let log = Logger(subsystem: "io.allsunday.motif", category: "Push")

    /// Latest APNs device token (hex), cached + persisted so a token that
    /// arrives before any server is connected can still be registered on the
    /// next connect.
    private(set) var deviceTokenHex: String? {
        didSet { UserDefaults.standard.set(deviceTokenHex, forKey: "motif.push.token") }
    }

    /// Observable app state, used to publish a tapped notification's deep link
    /// to the navigation layer. Weak — AppState owns PushManager indirectly via
    /// the shared singleton. Set early in ContentView.
    weak var appState: AppState? {
        didSet {
            // Flush a link captured during a cold launch-from-tap, before
            // appState was wired.
            if let buffered = bufferedLink, let a = appState {
                a.pendingDeepLink = buffered
                bufferedLink = nil
            }
        }
    }
    /// Holds a deep link that arrived before `appState` was set (cold launch).
    private var bufferedLink: PushDeepLink?

    /// Active server id for the current connection, captured at register time
    /// so `noteRegistered` can map instance_id → server.
    private var activeServerID: String?

    /// instance_id → server id mapping captured at register time, so a tapped
    /// notification can select the right configured server.
    private var instanceToServer: [String: String] = [:]

    /// APNs environment hint passed to the relay.
    var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// User-facing push switch (Terminal settings → gear). Default ON,
    /// persisted. This is the source of truth for "should this device receive
    /// pushes": ON ⇒ the device is registered with motifd; OFF ⇒ it's
    /// unregistered, so motifd drops its token and never pushes to it.
    private(set) var pushEnabled: Bool {
        didSet { UserDefaults.standard.set(pushEnabled, forKey: Self.enabledKey) }
    }
    private static let enabledKey = "motif.push.enabled"

    private override init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        pushEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        super.init()
        deviceTokenHex = UserDefaults.standard.string(forKey: "motif.push.token")
    }

    /// Flip the push switch. Persists immediately and reconciles registration
    /// with the connected server: enabling re-registers, disabling unregisters
    /// so motifd stops pushing to this device.
    func setPushEnabled(_ on: Bool) {
        guard on != pushEnabled else { return }
        pushEnabled = on
        Task {
            if on {
                // No token yet (push was off since launch, so we never asked):
                // request authorization now — didRegister will register once the
                // token arrives, if connected. Otherwise register straight away.
                if deviceTokenHex == nil {
                    await requestAuthorizationAndRegister()
                } else if let client = connectedClient {
                    await register(with: client)
                }
            } else if let client = connectedClient, let token = deviceTokenHex {
                await client.unregisterDevice(token: token)
            }
        }
    }

    // MARK: - Authorization + registration

    /// Request notification authorization and register for remote
    /// notifications. Call once early (e.g. from ContentView.task).
    func requestAuthorizationAndRegister() async {
        guard pushEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { log.notice("push authorization denied"); return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            infoLog("[Push] requestAuthorization failed: \(error)")
        }
    }

    /// Called by the app delegate when APNs hands us a token.
    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        deviceTokenHex = hex
        log.notice("apns token received (\(hex.count) hex chars)")
        // If a client is already connected, register immediately.
        if let client = connectedClient {
            Task { await register(with: client) }
        }
    }

    /// Hook the connected MotifClient so connect-time registration can reach it.
    weak var connectedClient: MotifClient?

    /// Register the current token + key with `client` (connected to the server
    /// `serverID`). Generates the per-device key on first use and stores it in
    /// the shared keychain for the extension. Idempotent — safe on every connect.
    func registerIfPossible(client: MotifClient, serverID: String) async {
        connectedClient = client
        activeServerID = serverID
        await register(with: client)
    }

    private func register(with client: MotifClient) async {
        guard pushEnabled else { return }
        guard let token = deviceTokenHex else { return }
        let keyB64 = ensureEncKeyBase64()
        await client.registerDevice(token: token, encKeyBase64: keyB64, environment: environment)
    }

    func noteRegistered(instanceID: String) {
        log.debug("registered with instance \(instanceID, privacy: .public)")
        if let sid = activeServerID {
            instanceToServer[instanceID] = sid
        }
    }

    func server(forInstance instanceID: String) -> String? {
        instanceToServer[instanceID]
    }

    // MARK: - Per-device encryption key (shared with the extension)

    /// Return the base64 AES-256-GCM key, generating + persisting it to the
    /// shared keychain on first use.
    private func ensureEncKeyBase64() -> String {
        if let existing = KeychainShared.get(account: PushConfig.encKeyAccount,
                                             group: PushConfig.keychainGroup) {
            return existing.base64EncodedString()
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        KeychainShared.set(raw, account: PushConfig.encKeyAccount, group: PushConfig.keychainGroup)
        return raw.base64EncodedString()
    }
}

// MARK: - Foreground presentation + tap routing

extension PushManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // App is foreground: suppress the system banner (the in-app live banner
        // driven by the `notification` event covers this) but keep the badge.
        // If the app isn't connected to the originating motifd, you may prefer
        // to return [.banner, .sound] instead — see checklist.
        return []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let motif = info["motif"] as? [String: Any] else { return }
        let link = PushDeepLink(
            instanceID: motif["instance_id"] as? String,
            sessionName: motif["session_id"] as? String
        )
        await MainActor.run {
            let pm = PushManager.shared
            if let a = pm.appState {
                a.pendingDeepLink = link
            } else {
                // Cold launch from a tap: appState isn't wired yet. Buffer and
                // flush when it's set.
                pm.bufferedLink = link
            }
        }
    }
}

struct PushDeepLink: Equatable {
    var instanceID: String?
    var sessionName: String?
}

// MARK: - App delegate adaptor

/// Bridges UIKit APNs callbacks into PushManager. Wire into MotifApp with
/// `@UIApplicationDelegateAdaptor(MotifAppDelegate.self) private var appDelegate`.
final class MotifAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        infoLog("[Push] APNs registration failed: \(error)")
    }
}

// MARK: - Minimal shared-keychain helper (app side)

/// A tiny keychain wrapper scoped to a shared access group so the Notification
/// Service Extension can read the same key. The repo's `Keychain` struct uses a
/// per-app service without an access group, so we keep this separate.
enum KeychainShared {
    static func set(_ data: Data, account: String, group: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String, group: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
