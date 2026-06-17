/// Desktop window show/hide for the tray-first ("accessory") model.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart';

import 'desktop_window.dart';

const MethodChannel _macChannel = MethodChannel('motif/desktop_window');

bool get _isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows);

class NativeDesktopWindowDelegate implements DesktopWindowDelegate {
  const NativeDesktopWindowDelegate();

  /// Bring the main window to the front (promoting to a regular, Dock-visible
  /// app on macOS).
  @override
  Future<void> show() async {
    if (!_isDesktop) return;
    if (_isMac) {
      try {
        await _macChannel.invokeMethod('show');
      } catch (_) {}
      return;
    }
    try {
      final w = WindowManager.instance.getCurrent();
      w?.show();
      w?.focus();
    } catch (_) {}
  }

  /// Hide the main window (dropping back to a Dock-less accessory app on macOS).
  @override
  Future<void> hide() async {
    if (!_isDesktop) return;
    if (_isMac) {
      try {
        await _macChannel.invokeMethod('hide');
      } catch (_) {}
      return;
    }
    try {
      WindowManager.instance.getCurrent()?.hide();
    } catch (_) {}
  }

  /// Open the main window on launch (promoting to a regular, Dock-visible app
  /// on macOS). Called once after the first frame so the window appears with
  /// content already rendered rather than blank. The red close button still
  /// drops it back to the tray.
  @override
  Future<void> showAtLaunch() => show();

  /// Whether this platform uses a Flutter-drawn custom title bar (macOS, where
  /// the window content extends into the title-bar band). The top toolbar must
  /// then inset for the traffic lights and host a drag region.
  @override
  bool get usesCustomTitleBar => _isMac;

  /// Begin a window-move drag from the custom title bar (macOS only). Call on
  /// pointer-down over a draggable title-bar region. No-op elsewhere.
  @override
  Future<void> startDrag() async {
    if (!_isMac) return;
    try {
      await _macChannel.invokeMethod('startDrag');
    } catch (_) {}
  }

  /// Stash the tray icon's native handle in the (process-lifetime) native side
  /// so the next isolate can clean it up after a hot restart. macOS only.
  @override
  Future<void> stashTrayHandle(int handle) async {
    if (!_isMac) return;
    try {
      await _macChannel.invokeMethod('stashTrayHandle', handle);
    } catch (_) {}
  }

  /// Destroy a tray icon left over from a previous isolate (a hot restart),
  /// natively, before creating a fresh one. No-op on a cold launch (nothing is
  /// stashed then) and on non-macOS.
  @override
  Future<void> cleanupStaleTray() async {
    if (!_isMac) return;
    try {
      await _macChannel.invokeMethod('cleanupStaleTray');
    } catch (_) {}
  }
}

void installDesktopWindowDelegate() {
  DesktopWindow.install(const NativeDesktopWindowDelegate());
}
