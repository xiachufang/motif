import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/desktop_launch.dart';

const _browserChannel = MethodChannel('motif/browser');

/// Parse an OSC 8 destination that Motif is willing to hand to the OS.
///
/// Terminal output is untrusted, so custom schemes and local `file:` URLs are
/// intentionally rejected. In a remote terminal those paths belong to the
/// remote host, not the device running Motif.
Uri? parseOpenableTerminalHyperlink(String value) {
  if (value.isEmpty || value != value.trim()) return null;
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x20 || codeUnit == 0x7f) return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return uri;
}

/// Open a validated OSC 8 destination with the platform's external browser.
Future<bool> openTerminalHyperlink(String value) async {
  final uri = parseOpenableTerminalHyperlink(value);
  if (uri == null || kIsWeb) return false;

  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      await openExternalUrl(uri.toString());
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      try {
        return await _browserChannel.invokeMethod<bool>('openUrl', {
              'url': uri.toString(),
            }) ??
            false;
      } on MissingPluginException {
        return false;
      } on PlatformException {
        return false;
      }
    case TargetPlatform.fuchsia:
      return false;
  }
}
