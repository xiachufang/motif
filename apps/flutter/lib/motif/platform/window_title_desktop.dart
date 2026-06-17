import 'package:flutter/foundation.dart';
import 'package:nativeapi/nativeapi.dart';

import 'window_title.dart';

bool get _isDesktopWindowPlatform =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;

class NativeWindowTitleDelegate implements WindowTitleDelegate {
  const NativeWindowTitleDelegate();

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<void> set(String title) async {
    if (!_isDesktopWindowPlatform) return;
    try {
      WindowManager.instance.getCurrent()?.title = title;
    } catch (_) {
      // Native window titles are best-effort. Flutter's Title widget remains as
      // a fallback.
    }
  }
}

void installDesktopWindowTitleDelegate() {
  MotifWindowTitle.install(const NativeWindowTitleDelegate());
}
