import 'package:flutter/foundation.dart';
import 'package:nativeapi/nativeapi.dart';

bool get _isDesktopWindowPlatform =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;

Future<void> ensureWindowTitleInitialized() async {}

Future<void> setWindowTitle(String title) async {
  if (!_isDesktopWindowPlatform) return;
  try {
    WindowManager.instance.getCurrent()?.title = title;
  } catch (_) {
    // Native window titles are best-effort. Flutter's Title widget remains as a
    // fallback, and mobile platforms intentionally no-op above.
  }
}
