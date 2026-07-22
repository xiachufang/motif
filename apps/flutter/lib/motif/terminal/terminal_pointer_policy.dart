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

/// Whether a desktop primary press is the explicit OSC 8 activation gesture.
///
/// This mirrors common terminal behavior: Command-click on macOS and
/// Control-click on Linux/Windows. Mobile links are activated by a plain tap.
bool terminalHyperlinkShouldActivate({
  required int buttons,
  required bool control,
  required bool meta,
  TargetPlatform? platform,
}) {
  if ((buttons & kPrimaryButton) == 0) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.macOS => meta,
    TargetPlatform.linux || TargetPlatform.windows => control,
    TargetPlatform.android ||
    TargetPlatform.fuchsia ||
    TargetPlatform.iOS => false,
  };
}

/// Whether the platform's terminal-link modifier is currently pressed.
///
/// Command is conventional on macOS; Control is used on Linux and Windows.
bool terminalLinkModifierPressed({
  required bool control,
  required bool meta,
  TargetPlatform? platform,
}) => switch (platform ?? defaultTargetPlatform) {
  TargetPlatform.macOS => meta,
  TargetPlatform.linux || TargetPlatform.windows => control,
  TargetPlatform.android ||
  TargetPlatform.fuchsia ||
  TargetPlatform.iOS => false,
};
