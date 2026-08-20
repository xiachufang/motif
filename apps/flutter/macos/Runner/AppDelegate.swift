import Cocoa
import Darwin
import FlutterMacOS

private typealias MotifEmbedStopFunction = @convention(c) () -> Int32

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Closing the window keeps the app, tray, and embedded server alive.
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      for window in sender.windows {
        if let mainWindow = window as? MainFlutterWindow {
          mainWindow.showWindow()
          break
        }
      }
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    stopEmbeddedServerIfLoaded()
    super.applicationWillTerminate(notification)
  }

  /// Dock Quit, the application menu, debugger termination, and other native
  /// exits can bypass Dart's quit command. Resolve the already-loaded native
  /// asset directly so its synchronous stop path runs before this process
  /// releases the embedded runtime.
  private func stopEmbeddedServerIfLoaded() {
    guard let frameworks = Bundle.main.privateFrameworksURL else { return }
    let path = frameworks
      .appendingPathComponent("motif_embed.framework")
      .appendingPathComponent("motif_embed")
      .path
    guard let handle = dlopen(path, RTLD_NOW | RTLD_NOLOAD) else { return }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "motif_embed_stop") else { return }
    let stop = unsafeBitCast(symbol, to: MotifEmbedStopFunction.self)
    _ = stop()
  }
}
