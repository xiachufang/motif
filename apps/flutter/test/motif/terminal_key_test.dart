import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_key.dart';

void main() {
  test('semantic keys normalize printable and Unicode logical keys', () {
    final bang = terminalKeySpecForCharacter('!')!;
    expect(bang.id, TerminalKeyIds.character('!'));
    expect(bang.logicalKey, LogicalKeyboardKey.digit1);
    expect(bang.implicitShift, isTrue);
    expect(bang.textFor(shift: false), '!');

    final normalized = terminalKeySpecForLogicalKey(
      LogicalKeyboardKey.exclamation,
    );
    expect(normalized?.id, bang.id);

    final capsLockA = terminalKeySpecForLogicalKey(
      LogicalKeyboardKey.keyA,
      character: 'A',
    );
    expect(capsLockA?.id, TerminalKeyIds.character('a'));
    expect(capsLockA?.implicitShift, isFalse);
  });

  test('hardware lookup preserves numpad Enter and arbitrary Unicode text', () {
    final numpadEnter = terminalKeySpecForLogicalKey(
      LogicalKeyboardKey.numpadEnter,
    );
    expect(numpadEnter?.ghosttyKey, 97);

    final unicode = terminalKeySpecForLogicalKey(
      LogicalKeyboardKey('中'.runes.single),
      character: '中',
    );
    expect(unicode?.ghosttyKey, 0);
    expect(unicode?.textFor(shift: false), '中');
    expect(unicode?.legacyBytes, utf8.encode('中'));
  });

  test('special keys carry stable Ghostty C API values', () {
    expect(terminalKeySpecForId(TerminalKeyIds.arrowUp)?.ghosttyKey, 78);
    expect(terminalKeySpecForId(TerminalKeyIds.backspace)?.ghosttyKey, 53);
    expect(terminalKeySpecForId(TerminalKeyIds.f12)?.ghosttyKey, 132);
  });

  test('legacy Shift-Tab migrates to Tab plus a semantic modifier', () {
    final match = legacyTerminalKeyForBytes(const [0x1b, 0x5b, 0x5a]);
    expect(match?.keyId, TerminalKeyIds.tab);
    expect(match?.shift, isTrue);
  });
}
