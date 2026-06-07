import 'package:flutter/services.dart';
import 'package:motif/motif/terminal/web_key_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('encodeKeyToBytes', () {
    test('printable char', () {
      expect(
        encodeKeyToBytes(LogicalKeyboardKey.keyA, 'a', const TerminalKeyMods()),
        [0x61],
      );
    });

    test('Enter / Tab / Esc / Backspace', () {
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.enter,
          null,
          const TerminalKeyMods(),
        ),
        [0x0d],
      );
      expect(
        encodeKeyToBytes(LogicalKeyboardKey.tab, null, const TerminalKeyMods()),
        [0x09],
      );
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.escape,
          null,
          const TerminalKeyMods(),
        ),
        [0x1b],
      );
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.backspace,
          null,
          const TerminalKeyMods(),
        ),
        [0x7f],
      );
    });

    test('arrows', () {
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.arrowUp,
          null,
          const TerminalKeyMods(),
        ),
        [0x1b, 0x5b, 0x41],
      );
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.arrowLeft,
          null,
          const TerminalKeyMods(),
        ),
        [0x1b, 0x5b, 0x44],
      );
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.arrowRight,
          null,
          const TerminalKeyMods(),
        ),
        [0x1b, 0x5b, 0x43],
      );
    });

    test('navigation keys', () {
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.home,
          null,
          const TerminalKeyMods(),
        ),
        [0x1b, 0x5b, 0x48],
      );
      expect(
        encodeKeyToBytes(LogicalKeyboardKey.end, null, const TerminalKeyMods()),
        [0x1b, 0x5b, 0x46],
      );
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.delete,
          null,
          const TerminalKeyMods(),
        ),
        [0x1b, 0x5b, 0x33, 0x7e],
      );
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.pageUp,
          null,
          const TerminalKeyMods(),
        ),
        [0x1b, 0x5b, 0x35, 0x7e],
      );
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.pageDown,
          null,
          const TerminalKeyMods(),
        ),
        [0x1b, 0x5b, 0x36, 0x7e],
      );
    });

    test('Ctrl+C → 0x03', () {
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.keyC,
          'c',
          const TerminalKeyMods(ctrl: true),
        ),
        [0x03],
      );
    });

    test('Alt+char prefixes ESC', () {
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.keyB,
          'b',
          const TerminalKeyMods(alt: true),
        ),
        [0x1b, 0x62],
      );
    });

    test(
      'shifted digit resolves to symbol when event character is missing or raw',
      () {
        expect(
          encodeKeyToBytes(
            LogicalKeyboardKey.digit1,
            null,
            const TerminalKeyMods(shift: true),
          ),
          [0x21],
        );
        expect(
          encodeKeyToBytes(
            LogicalKeyboardKey.digit1,
            '1',
            const TerminalKeyMods(shift: true),
          ),
          [0x21],
        );
      },
    );

    test('Ctrl+Shift and Ctrl+Alt combinations', () {
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.keyC,
          'C',
          const TerminalKeyMods(ctrl: true, shift: true),
        ),
        [0x03],
      );
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.keyC,
          'c',
          const TerminalKeyMods(ctrl: true, alt: true),
        ),
        [0x1b, 0x03],
      );
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.digit2,
          null,
          const TerminalKeyMods(ctrl: true, shift: true),
        ),
        [0x00],
      );
    });

    test('Alt+named key prefixes ESC', () {
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.arrowUp,
          null,
          const TerminalKeyMods(alt: true),
        ),
        [0x1b, 0x1b, 0x5b, 0x41],
      );
    });

    test('unhandled modifier-only key returns null', () {
      expect(
        encodeKeyToBytes(
          LogicalKeyboardKey.shiftLeft,
          null,
          const TerminalKeyMods(),
        ),
        isNull,
      );
    });
  });
}
