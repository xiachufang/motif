/// Shared desktop-window facade. Default implementation is pure Dart and
/// no-op, so web/mobile builds do not compile the desktop nativeapi package.
/// The desktop entrypoint installs a native implementation at startup.
library;

abstract interface class DesktopWindowDelegate {
  Future<void> show();
  Future<void> hide();
  Future<void> showAtLaunch();
  bool get usesCustomTitleBar;
  Future<void> startDrag();
  Future<void> stashTrayHandle(int handle);
  Future<void> cleanupStaleTray();
}

class NoopDesktopWindowDelegate implements DesktopWindowDelegate {
  const NoopDesktopWindowDelegate();

  @override
  Future<void> show() async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> showAtLaunch() async {}

  @override
  bool get usesCustomTitleBar => false;

  @override
  Future<void> startDrag() async {}

  @override
  Future<void> stashTrayHandle(int handle) async {}

  @override
  Future<void> cleanupStaleTray() async {}
}

abstract final class DesktopWindow {
  static DesktopWindowDelegate _delegate = const NoopDesktopWindowDelegate();

  static void install(DesktopWindowDelegate delegate) {
    _delegate = delegate;
  }

  static Future<void> show() => _delegate.show();

  static Future<void> hide() => _delegate.hide();

  static Future<void> showAtLaunch() => _delegate.showAtLaunch();

  static bool get usesCustomTitleBar => _delegate.usesCustomTitleBar;

  static Future<void> startDrag() => _delegate.startDrag();

  static Future<void> stashTrayHandle(int handle) =>
      _delegate.stashTrayHandle(handle);

  static Future<void> cleanupStaleTray() => _delegate.cleanupStaleTray();
}
