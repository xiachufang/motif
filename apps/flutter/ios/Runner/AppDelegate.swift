import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Held while waiting for the APNs token delegate callback.
  private var pendingTokenResult: FlutterResult?
  private var pushChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Native APNs bridge (no Firebase). The Dart ApnsPushService drives this:
    //   requestAuthorization → registerForRemoteNotifications → device token.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MotifPush") {
      let channel = FlutterMethodChannel(name: "motif/push",
                                         binaryMessenger: registrar.messenger())
      pushChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "requestAuthorization":
          UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
          ) { granted, _ in
            DispatchQueue.main.async { result(granted) }
          }
        case "registerForRemoteNotifications":
          self?.pendingTokenResult = result
          UIApplication.shared.registerForRemoteNotifications()
        case "unregister":
          UIApplication.shared.unregisterForRemoteNotifications()
          result(nil)
        case "storeEncKey":
          // Mirror the per-device AES key into the App Group keychain so the
          // Notification Service Extension can decrypt background pushes.
          let key = (call.arguments as? [String: Any])?["key"] as? String
          result(self?.storeEncKey(key) ?? false)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MotifBrowser") {
      MotifBrowserChannel.register(binaryMessenger: registrar.messenger())
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    pendingTokenResult?(hex)
    pendingTokenResult = nil
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    pendingTokenResult?(nil)
    pendingTokenResult = nil
  }

  // Foreground push: forward the encrypted (e, n) fields to Dart, which
  // decrypts in-app and shows the banner. (Background/killed delivery is
  // decrypted by the Notification Service Extension instead.)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    forwardEncryptedPayload(notification.request.content.userInfo)
    completionHandler([]) // we render our own in-app banner
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    forwardEncryptedPayload(userInfo)
    completionHandler(.noData)
  }

  private func forwardEncryptedPayload(_ userInfo: [AnyHashable: Any]) {
    guard let e = userInfo["e"] as? String, let n = userInfo["n"] as? String else { return }
    pushChannel?.invokeMethod("onPush", arguments: ["e": e, "n": n])
  }

  // Write the base64 AES key into the shared App Group keychain under the
  // account/group the NSE (NotificationService.swift) reads from.
  private static let keyAccount = "motif.push.encKey"
  private static let accessGroup = "group.io.allsunday.motif"

  private func storeEncKey(_ keyBase64: String?) -> Bool {
    guard let keyBase64, let data = keyBase64.data(using: .utf8) else { return false }
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: AppDelegate.keyAccount,
      kSecAttrAccessGroup as String: AppDelegate.accessGroup,
    ]
    SecItemDelete(base as CFDictionary) // replace any prior value
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }
}

enum MotifBrowserChannel {
  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "motif/browser",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "openUrl":
        let urlString = (call.arguments as? [String: Any])?["url"] as? String
        guard let urlString, let url = URL(string: urlString) else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
          result(opened)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
