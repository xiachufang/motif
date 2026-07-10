/// Desktop window show/hide for the regular desktop app shell.
library;

import 'dart:io';

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

  /// Bring the main window to the front.
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

  /// Hide the main window while keeping the app and tray alive.
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

  /// Open the main window on launch. Called once after the first frame so the
  /// window appears with content already rendered rather than blank.
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

  /// Terminate the whole desktop app. macOS goes through NSApplication so its
  /// normal termination lifecycle runs; the other desktop shells currently
  /// use the same process exit path as the tray menu did historically.
  @override
  Future<void> quit() async {
    if (!_isDesktop) return;
    if (_isMac) {
      try {
        await _macChannel.invokeMethod('quit');
      } catch (_) {}
      return;
    }
    exit(0);
  }
}

void installDesktopWindowDelegate() {
  DesktopWindow.install(const NativeDesktopWindowDelegate());
}
