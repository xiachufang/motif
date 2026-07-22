import Flutter
import ObjectiveC.runtime
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Held while waiting for the APNs token delegate callback.
  private var pendingTokenResult: FlutterResult?
  private var pushChannel: FlutterMethodChannel?
  /// Cold-start / early tap payload held until Dart asks for it (or the
  /// MethodChannel is ready to push `onNotificationOpen`).
  private var pendingNotificationOpen: [String: String]?

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
          // Mirror the per-device AES key into the App Group container so the
          // Notification Service Extension can decrypt background pushes.
          let key = (call.arguments as? [String: Any])?["key"] as? String
          result(self?.storeEncKey(key) ?? false)
        case "takePendingNotificationOpen":
          // Cold start: Dart drains any tap that arrived before the channel
          // handler was registered.
          let pending = self?.pendingNotificationOpen
          self?.pendingNotificationOpen = nil
          result(pending)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      // If a tap arrived before the channel existed, flush it now.
      if let pending = pendingNotificationOpen {
        pendingNotificationOpen = nil
        channel.invokeMethod("onNotificationOpen", arguments: pending)
      }
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MotifBrowser") {
      MotifBrowserChannel.register(binaryMessenger: registrar.messenger())
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MotifImeDocument") {
      MotifImeDocumentChannel.register(binaryMessenger: registrar.messenger())
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

  // User tapped a system notification (background / cold start). NSE already
  // decrypted and stashed session / instance_id into userInfo.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    forwardNotificationOpen(response.notification.request.content.userInfo)
    completionHandler()
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

  private func forwardNotificationOpen(_ userInfo: [AnyHashable: Any]) {
    var payload: [String: String] = [:]
    if let session = userInfo["session"] as? String, !session.isEmpty {
      payload["session"] = session
    } else if let session = userInfo["session_id"] as? String, !session.isEmpty {
      payload["session"] = session
    }
    if let instanceId = userInfo["instance_id"] as? String, !instanceId.isEmpty {
      payload["instance_id"] = instanceId
    }
    if let viewId = userInfo["view_id"] as? String, !viewId.isEmpty {
      payload["view_id"] = viewId
    }
    guard !payload.isEmpty else { return }
    if let channel = pushChannel {
      channel.invokeMethod("onNotificationOpen", arguments: payload)
    } else {
      pendingNotificationOpen = payload
    }
  }

  // Write the base64 AES key into the shared App Group container the NSE
  // (NotificationService.swift) reads from. Keep a keychain fallback for builds
  // that add Keychain Sharing later.
  private static let keyAccount = "motif.push.encKey"
  private static let appGroup = "group.io.allsunday.motif"
  private static let keyFileName = "motif-push-enc-key"

  private func storeEncKey(_ keyBase64: String?) -> Bool {
    guard let keyBase64, let data = keyBase64.data(using: .utf8) else { return false }
    if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppDelegate.appGroup) {
      let url = dir.appendingPathComponent(AppDelegate.keyFileName, isDirectory: false)
      do {
        try data.write(to: url, options: [.atomic])
        try? (url as NSURL).setResourceValue(
          URLFileProtection.completeUntilFirstUserAuthentication,
          forKey: .fileProtectionKey
        )
        return true
      } catch {}
    }

    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: AppDelegate.keyAccount,
      kSecAttrAccessGroup as String: AppDelegate.appGroup,
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

enum MotifImeDocumentChannel {
  static func register(binaryMessenger: FlutterBinaryMessenger) {
    MotifIosImeDocumentCoordinator.shared.installFlutterTextInputContextIdentifierHook()

    let channel = FlutterMethodChannel(
      name: "motif/ime_document",
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "activateDocument":
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? String else {
          result(FlutterError(
            code: "bad_args",
            message: "activateDocument requires an id",
            details: nil))
          return
        }
        let defaultEnglish = args["defaultEnglish"] as? Bool ?? false
        MotifIosImeDocumentCoordinator.shared.activateDocument(
          id,
          defaultEnglish: defaultEnglish)
        result(nil)
      case "disposeDocument":
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? String else {
          result(FlutterError(
            code: "bad_args",
            message: "disposeDocument requires an id",
            details: nil))
          return
        }
        MotifIosImeDocumentCoordinator.shared.disposeDocument(id)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

private final class MotifIosImeDocumentCoordinator {
  static let shared = MotifIosImeDocumentCoordinator()

  private let fallbackDocumentId = "__motif_default__"
  private let contextIdentifierPrefix = "io.allsunday.motif.ime-document."
  private var currentDocumentId = "__motif_default__"
  private var hookInstalled = false

  private init() {}

  func installFlutterTextInputContextIdentifierHook() {
    guard !hookInstalled else { return }
    guard let textInputViewClass = NSClassFromString("FlutterTextInputView") else {
      return
    }

    let selector = #selector(getter: UIResponder.textInputContextIdentifier)
    let block: @convention(block) (AnyObject) -> NSString? = { _ in
      MotifIosImeDocumentCoordinator.shared.currentContextIdentifier as NSString
    }
    let implementation = imp_implementationWithBlock(block)
    class_replaceMethod(textInputViewClass, selector, implementation, "@@:")
    hookInstalled = true
  }

  func activateDocument(_ id: String, defaultEnglish: Bool) {
    guard !id.isEmpty else { return }
    DispatchQueue.main.async {
      self.installFlutterTextInputContextIdentifierHook()
      self.currentDocumentId = id

      // iOS has no public API to select a keyboard input source. Clearing a
      // brand-new identifier avoids restoring another tab's remembered mode, so
      // a fresh tab falls back to the Dart config's English locale hint. That
      // config uses a plain text keyboard (not ASCII-capable), so the globe key
      // still reaches CJK IMEs and each tab's identifier remembers its choice.
      if defaultEnglish {
        UIResponder.clearTextInputContextIdentifier(
          self.contextIdentifier(for: id))
      }

      self.reloadCurrentTextInput()
    }
  }

  func disposeDocument(_ id: String) {
    guard !id.isEmpty else { return }
    DispatchQueue.main.async {
      UIResponder.clearTextInputContextIdentifier(self.contextIdentifier(for: id))
      if self.currentDocumentId == id {
        self.currentDocumentId = self.fallbackDocumentId
        self.reloadCurrentTextInput()
      }
    }
  }

  private var currentContextIdentifier: String {
    contextIdentifier(for: currentDocumentId)
  }

  private func contextIdentifier(for id: String) -> String {
    contextIdentifierPrefix + id
  }

  private func reloadCurrentTextInput() {
    currentFlutterTextInputResponder()?.reloadInputViews()
  }

  private func currentFlutterTextInputResponder() -> UIResponder? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows where window.isKeyWindow {
        guard let responder = window.motifFirstResponder() else { continue }
        if NSStringFromClass(type(of: responder)).contains("FlutterTextInputView") {
          return responder
        }
      }
    }
    return nil
  }
}

private extension UIView {
  func motifFirstResponder() -> UIResponder? {
    if isFirstResponder { return self }
    for subview in subviews {
      if let responder = subview.motifFirstResponder() {
        return responder
      }
    }
    return nil
  }
}
