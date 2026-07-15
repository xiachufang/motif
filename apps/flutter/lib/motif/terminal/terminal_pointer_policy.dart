import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// Whether a pointer press should open Motif's terminal context menu.
///
/// Desktop secondary clicks are owned by the terminal surface regardless of
/// whether text is currently selected. Mobile selection continues to use its
/// adaptive copy toolbar.
bool terminalContextMenuShouldOpen({
  required int buttons,
  TargetPlatform? platform,
}) {
  final target = platform ?? defaultTargetPlatform;
  final desktop = switch (target) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    TargetPlatform.android ||
    TargetPlatform.fuchsia ||
    TargetPlatform.iOS => false,
  };
  return desktop && (buttons & kSecondaryButton) != 0;
}
