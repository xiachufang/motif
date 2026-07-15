import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_focus_policy.dart';

void main() {
  test('selection focus preserves the current viewport', () {
    expect(TerminalFocusIntent.textSelection.revealBottom, isFalse);
  });

  test('keyboard-oriented focus reveals the live cursor', () {
    expect(TerminalFocusIntent.keyboardInput.revealBottom, isTrue);
  });

  test('tap does not request input focus when selection was active', () {
    expect(terminalTapRequestsFocus(selectionActive: true), isFalse);
  });

  test('tap requests input focus when there is no selection', () {
    expect(terminalTapRequestsFocus(selectionActive: false), isTrue);
  });

  test('tab switch autofocus is disabled on mobile platforms', () {
    expect(
      terminalAutofocusesOnTabSwitchByDefault(platform: TargetPlatform.iOS),
      isFalse,
    );
    expect(
      terminalAutofocusesOnTabSwitchByDefault(platform: TargetPlatform.android),
      isFalse,
    );
  });

  test('tab switch autofocus is enabled on non-mobile platforms', () {
    for (final platform in [
      TargetPlatform.fuchsia,
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      expect(
        terminalAutofocusesOnTabSwitchByDefault(platform: platform),
        isTrue,
        reason: '$platform',
      );
    }
  });
}
