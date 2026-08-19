/// Hand a URL to the desktop OS's default browser, without pulling in a
/// plugin. Mirrors the Tauri menu-bar app's `open_in_default_browser`: the
/// platform launcher (`open` / `xdg-open` / `start`), args passed directly so
/// the URL can't be reinterpreted by a shell. Desktop only; a no-op elsewhere.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

Future<void> openExternalUrl(String url) async {
  if (kIsWeb) return;
  // Only hand off well-formed http(s) URLs to the OS launcher.
  if (!(url.startsWith('http://') || url.startsWith('https://'))) return;
  try {
    if (Platform.isMacOS) {
      await Process.start('open', [url]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [url]);
    } else if (Platform.isWindows) {
      // `start` is a cmd builtin; the empty "" is the window-title arg so a
      // quoted URL isn't mistaken for the title.
      await Process.start('cmd', ['/C', 'start', '', url]);
    }
  } catch (_) {
    // Best-effort; nothing actionable if the launcher is missing.
  }
}

/// Opens a local file with the desktop shell's default application. The path is
/// passed as a process argument rather than interpolated into a shell command.
Future<bool> openDesktopFile(String path) async {
  if (kIsWeb || path.isEmpty) return false;
  try {
    if (Platform.isMacOS) {
      await Process.start('open', [path]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path]);
    } else if (Platform.isWindows) {
      await Process.start('explorer.exe', [path]);
    } else {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}
