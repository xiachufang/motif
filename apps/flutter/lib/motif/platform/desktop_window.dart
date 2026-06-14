/// Desktop window show/hide for the tray-first ("accessory") model: the app
/// lives in the tray and the window appears on demand. On macOS this also
/// toggles the app's activation policy (Dock icon present only while a window
/// is showing) via a platform method channel — the same Dock dance the Tauri
/// menu-bar app does. On Windows/Linux it hides/shows the native window
/// through `nativeapi`. No-op on web/mobile.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart';

const MethodChannel _macChannel = MethodChannel('motif/desktop_window');

bool get _isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows);

abstract final class DesktopWindow {
  /// Bring the main window to the front (promoting to a regular, Dock-visible
  /// app on macOS).
  static Future<void> show() async {
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
  static Future<void> hide() async {
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

  /// Start in the tray with no window shown. Called once at launch.
  static Future<void> hideAtLaunch() => hide();

  /// Whether this platform uses a Flutter-drawn custom title bar (macOS, where
  /// the window content extends into the title-bar band). The top toolbar must
  /// then inset for the traffic lights and host a drag region.
  static bool get usesCustomTitleBar => _isMac;

  /// Begin a window-move drag from the custom title bar (macOS only). Call on
  /// pointer-down over a draggable title-bar region. No-op elsewhere.
  static Future<void> startDrag() async {
    if (!_isMac) return;
    try {
      await _macChannel.invokeMethod('startDrag');
    } catch (_) {}
  }
}
