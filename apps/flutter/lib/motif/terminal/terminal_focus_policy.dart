import 'package:flutter/foundation.dart';

/// Why a terminal surface is claiming keyboard focus.
///
/// Focusing for text selection must preserve the viewport: selection gestures
/// use coordinates from the currently visible rows. Keyboard-oriented focus
/// may reveal the live cursor at the bottom as before.
enum TerminalFocusIntent {
  keyboardInput(revealBottom: true),
  textSelection(revealBottom: false);

  const TerminalFocusIntent({required this.revealBottom});

  final bool revealBottom;
}

/// Whether changing the active terminal tab should claim keyboard focus by
/// default.
///
/// iOS and Android keep tab switches passive so they do not pop the soft
/// keyboard. Desktop-like platforms focus the terminal so hardware-keyboard
/// input continues to work after switching tabs.
bool terminalAutofocusesOnTabSwitchByDefault({TargetPlatform? platform}) {
  final target = platform ?? defaultTargetPlatform;
  return switch (target) {
    TargetPlatform.iOS || TargetPlatform.android => false,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
  };
}
