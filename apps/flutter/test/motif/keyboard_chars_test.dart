import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/keyboard_chars.dart';
import 'package:motif/motif/terminal/web_key_encoder.dart';

void main() {
  test('shifted physical keys resolve to printable text', () {
    expect(
      logicalKeyEventCharacter(LogicalKeyboardKey.keyA, null, shift: true),
      'A',
    );
    expect(
      logicalKeyEventCharacter(LogicalKeyboardKey.digit1, null, shift: true),
      '!',
    );
    expect(
      logicalKeyEventCharacter(LogicalKeyboardKey.semicolon, null, shift: true),
      ':',
    );
  });

  test('shifted unicode logical keys resolve without physical-key mapping', () {
    expect(
      logicalKeyEventCharacter(
        LogicalKeyboardKey.exclamation,
        null,
        shift: true,
      ),
      '!',
    );
    expect(
      logicalKeyEventCharacter(LogicalKeyboardKey.colon, null, shift: true),
      ':',
    );
    expect(
      logicalKeyEventCharacter(
        LogicalKeyboardKey.quoteSingle,
        null,
        shift: false,
      ),
      "'",
    );
    expect(
      logicalKeyEventCharacter(LogicalKeyboardKey.braceLeft, null, shift: true),
      '{',
    );
  });

  test('printable terminal text excludes control characters', () {
    expect(isPrintableTerminalText('A'), isTrue);
    expect(isPrintableTerminalText('!'), isTrue);
    expect(isPrintableTerminalText(' '), isTrue);
    expect(isPrintableTerminalText('\n'), isFalse);
    expect(isPrintableTerminalText('\x7f'), isFalse);
  });

  test('web encoder accepts shifted unicode logical keys', () {
    expect(
      encodeKeyToBytes(
        LogicalKeyboardKey.exclamation,
        null,
        const TerminalKeyMods(shift: true),
      ),
      '!'.codeUnits,
    );
    expect(
      encodeKeyToBytes(
        LogicalKeyboardKey.colon,
        null,
        const TerminalKeyMods(shift: true),
      ),
      ':'.codeUnits,
    );
  });
}
