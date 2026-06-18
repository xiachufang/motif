import Cocoa
import FlutterMacOS
import ObjectiveC.runtime

// C symbol from the linked cnativeapi library (the tray plugin's backend),
// used to destroy a stale tray icon left over from a hot restart by its raw
// native handle. Declared here so we don't need a bridging header.
@_silgen_name("native_tray_icon_destroy")
func native_tray_icon_destroy(_ trayIcon: UnsafeMutableRawPointer)

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  // Native handle of the tray icon Dart created, stashed so that after a hot
  // restart the new Dart isolate can destroy the stale native tray (whose FFI
  // callbacks were deleted with the old isolate) before making a fresh one.
  // The window survives hot restart, so this persists across it — but a cold
  // launch starts with nil, which correctly means "nothing to clean up".
  private var stashedTrayHandle: Int?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Dart drives show/hide over this channel. The app is a regular Dock app;
    // the tray remains as an additional quick-access surface.
    let channel = FlutterMethodChannel(
      name: "motif/desktop_window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "show":
        self?.showWindow()
        result(nil)
      case "hide":
        self?.hideWindow()
        result(nil)
      case "startDrag":
        // Drag the window from the Flutter custom title bar, using the
        // in-flight mouse event.
        if let event = NSApp.currentEvent {
          self?.performDrag(with: event)
        }
        result(nil)
      case "stashTrayHandle":
        self?.stashedTrayHandle = call.arguments as? Int
        result(nil)
      case "cleanupStaleTray":
        // After a hot restart the previous isolate's native tray lingers with
        // dangling FFI callbacks. Destroy it (the symbol is in the linked
        // cnativeapi library) before the new isolate makes a fresh one. A cold
        // launch has nothing stashed, so this is a no-op then.
        if let h = self?.stashedTrayHandle,
           let ptr = UnsafeMutableRawPointer(bitPattern: h) {
          native_tray_icon_destroy(ptr)
        }
        self?.stashedTrayHandle = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    MotifImeDocumentCoordinator.shared.installFlutterTextInputContextHook()
    let imeDocumentChannel = FlutterMethodChannel(
      name: "motif/ime_document",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    imeDocumentChannel.setMethodCallHandler { call, result in
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
        MotifImeDocumentCoordinator.shared.activateDocument(
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
        MotifImeDocumentCoordinator.shared.disposeDocument(id)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    self.delegate = self
    super.awakeFromNib()

    // Custom title bar: extend the Flutter content into the title-bar band and
    // hide the system title, so the Client/Server switch toolbar can act as the
    // title bar. Set after super.awakeFromNib() so nib loading can't reset it.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    // Drop the system separator under the title bar — the Flutter toolbar draws
    // its own bottom border, and the native one shows a shadow that flashes as
    // content "scrolls under" the title bar on a view switch.
    if #available(macOS 11.0, *) {
      self.titlebarSeparatorStyle = .none
    }

  }

  /// Bring the main window to the front.
  func showWindow() {
    NSApp.activate(ignoringOtherApps: true)
    self.makeKeyAndOrderFront(nil)
  }

  /// Hide the main window while keeping the app and embedded server alive.
  func hideWindow() {
    self.orderOut(nil)
  }

  /// The red close button hides the window (keeping the app + embedded server
  /// alive in the tray) rather than closing/terminating.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideWindow()
    return false
  }
}

private final class MotifImeDocumentCoordinator {
  static let shared = MotifImeDocumentCoordinator()

  private let fallbackDocumentId = "__motif_default__"
  private let englishInputSourceIds = [
    "com.apple.keylayout.ABC",
    "com.apple.keylayout.US",
    "com.apple.keyboardlayout.US",
    "com.apple.keylayout.USExtended",
  ]
  private var currentDocumentId = "__motif_default__"
  private var contexts: [String: NSTextInputContext] = [:]
  private var pendingEnglishDefaultDocumentIds: Set<String> = []
  private var textInputContextIvar: Ivar?
  private var swizzleInstalled = false

  private init() {}

  func installFlutterTextInputContextHook() {
    guard !swizzleInstalled else { return }
    guard let textInputClass = NSClassFromString("FlutterTextInputPlugin") else {
      return
    }
    let originalSelector = Selector(("inputContext"))
    let replacementSelector = #selector(NSObject.motifInputContextForDocument)
    guard let originalMethod = class_getInstanceMethod(textInputClass, originalSelector),
          let replacementMethod = class_getInstanceMethod(NSObject.self, replacementSelector) else {
      return
    }
    let added = class_addMethod(
      textInputClass,
      replacementSelector,
      method_getImplementation(replacementMethod),
      method_getTypeEncoding(replacementMethod))
    guard added,
          let addedMethod = class_getInstanceMethod(textInputClass, replacementSelector) else {
      return
    }
    method_exchangeImplementations(originalMethod, addedMethod)
    swizzleInstalled = true
  }

  func activateDocument(_ id: String, defaultEnglish: Bool) {
    installFlutterTextInputContextHook()
    let nextDocumentId = normalizedDocumentId(id)
    DispatchQueue.main.async {
      let previousContext = self.currentFlutterTextInputContext()
      previousContext?.deactivate()
      self.currentDocumentId = nextDocumentId
      if defaultEnglish {
        self.pendingEnglishDefaultDocumentIds.insert(nextDocumentId)
      }
      let nextContext = self.currentFlutterTextInputContext()
      nextContext?.activate()
      self.applyPendingEnglishDefaultIfNeeded(
        to: nextContext,
        documentId: nextDocumentId)
    }
  }

  func disposeDocument(_ id: String) {
    let documentId = normalizedDocumentId(id)
    DispatchQueue.main.async {
      if self.currentDocumentId == documentId {
        self.currentFlutterTextInputContext()?.deactivate()
        self.currentDocumentId = self.fallbackDocumentId
      }
      self.pendingEnglishDefaultDocumentIds.remove(documentId)
      let suffix = ":\(documentId)"
      for key in Array(self.contexts.keys) where key.hasSuffix(suffix) {
        self.contexts.removeValue(forKey: key)
      }
    }
  }

  func inputContext(for client: NSTextInputClient, owner: NSObject) -> NSTextInputContext {
    let documentId = currentDocumentId
    let key = contextKey(client: client, documentId: documentId)
    let context: NSTextInputContext
    if let existing = contexts[key] {
      context = existing
    } else {
      context = NSTextInputContext(client: client)
      contexts[key] = context
    }
    install(context: context, on: owner)
    applyPendingEnglishDefaultIfNeeded(to: context, documentId: documentId)
    return context
  }

  private func normalizedDocumentId(_ id: String) -> String {
    id.isEmpty ? fallbackDocumentId : id
  }

  private func contextKey(client: NSTextInputClient, documentId: String) -> String {
    let clientId = ObjectIdentifier(client as AnyObject).hashValue
    return "\(clientId):\(documentId)"
  }

  private func currentFlutterTextInputContext() -> NSTextInputContext? {
    guard let responder = NSApp.keyWindow?.firstResponder as? NSObject else { return nil }
    guard NSStringFromClass(type(of: responder)).contains("FlutterTextInputPlugin") else {
      return nil
    }
    guard let client = responder as? NSTextInputClient else { return nil }
    return inputContext(for: client, owner: responder)
  }

  private func install(context: NSTextInputContext, on owner: NSObject) {
    guard let ivar = flutterTextInputContextIvar(for: owner) else { return }
    object_setIvar(owner, ivar, context)
  }

  private func flutterTextInputContextIvar(for owner: NSObject) -> Ivar? {
    if let textInputContextIvar {
      return textInputContextIvar
    }
    var currentClass: AnyClass? = object_getClass(owner)
    while let cls = currentClass {
      if let ivar = class_getInstanceVariable(cls, "_textInputContext") {
        textInputContextIvar = ivar
        return ivar
      }
      currentClass = class_getSuperclass(cls)
    }
    return nil
  }

  private func applyPendingEnglishDefaultIfNeeded(
    to context: NSTextInputContext?,
    documentId: String
  ) {
    guard pendingEnglishDefaultDocumentIds.contains(documentId),
          let context else {
      return
    }
    guard let source = preferredEnglishInputSource(in: context.keyboardInputSources) else {
      return
    }
    pendingEnglishDefaultDocumentIds.remove(documentId)
    context.selectedKeyboardInputSource = source
  }

  private func preferredEnglishInputSource(
    in sources: [NSTextInputSourceIdentifier]?
  ) -> NSTextInputSourceIdentifier? {
    guard let sources, !sources.isEmpty else { return nil }
    for id in englishInputSourceIds where sources.contains(id) {
      return id
    }
    return sources.first { id in
      id.localizedCaseInsensitiveContains("ABC") ||
        id.localizedCaseInsensitiveContains("US")
    }
  }
}

private extension NSObject {
  @objc func motifInputContextForDocument() -> NSTextInputContext? {
    guard let client = self as? NSTextInputClient else { return nil }
    return MotifImeDocumentCoordinator.shared.inputContext(for: client, owner: self)
  }
}
