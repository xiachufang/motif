import Cocoa
import FlutterMacOS

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

    // Tray-first model: the app lives in the menu-bar tray and the window
    // appears on demand. Dart drives show/hide (and the Dock-icon dance) over
    // this channel — the same activation-policy promotion the Tauri menu-bar
    // app does for an Accessory app.
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

    // Show the window on whatever Space (desktop) is currently active, instead
    // of yanking the user back to the Space the window was last shown on. A
    // plain window is bound to its home Space, so `makeKeyAndOrderFront` from a
    // different Space would switch desktops; `.moveToActiveSpace` makes the
    // window follow the user instead.
    self.collectionBehavior = [.moveToActiveSpace]

    // Start hidden in the tray (no flash thanks to LSUIElement).
    self.orderOut(nil)
  }

  /// Promote to a regular, Dock-visible app and bring the window front.
  func showWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    self.makeKeyAndOrderFront(nil)
  }

  /// Hide the window and drop back to a Dock-less accessory app.
  func hideWindow() {
    self.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  /// The red close button hides the window (keeping the app + embedded server
  /// alive in the tray) rather than closing/terminating.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideWindow()
    return false
  }
}
