import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    self.delegate = self
    super.awakeFromNib()

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
