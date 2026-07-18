import 'package:flutter/foundation.dart';

/// Whether a completed terminal tap should enter keyboard-input focus.
///
/// A tap that starts while text is selected belongs to the selection UI. It
/// must not reveal the live cursor and move the viewport away from the selected
/// rows, even when that tap clears the selection.
bool terminalTapRequestsFocus({required bool selectionActive}) {
  return !selectionActive;
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
