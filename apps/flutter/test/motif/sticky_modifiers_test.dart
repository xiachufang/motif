import 'dart:typed_data';

import 'package:motif/motif/state/sticky_modifiers.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(List<int> b) => Uint8List.fromList(b);

void main() {
  group('applyModifiers', () {
    test('ctrl maps letter to control code', () {
      // Ctrl+C → 0x03
      expect(applyModifiers(_b([0x63]), ctrl: true), _b([0x03]));
    });

    test('shift uppercases a single letter', () {
      expect(applyModifiers(_b([0x61]), shift: true), _b([0x41])); // a → A
    });

    test('shift maps digits and punctuation to symbols', () {
      expect(applyModifiers(_b([0x31]), shift: true), _b([0x21])); // 1 -> !
      expect(applyModifiers(_b([0x3d]), shift: true), _b([0x2b])); // = -> +
    });

    test('alt prefixes ESC', () {
      expect(applyModifiers(_b([0x62]), alt: true), _b([0x1b, 0x62]));
    });

    test('ctrl+alt combine', () {
      // Alt+Ctrl+C → ESC, 0x03
      expect(
        applyModifiers(_b([0x63]), ctrl: true, alt: true),
        _b([0x1b, 0x03]),
      );
    });

    test('multi-byte payloads only receive an alt ESC prefix', () {
      final up = _b([0x1b, 0x5b, 0x41]); // arrow up
      expect(applyModifiers(up, ctrl: true), up); // ctrl ignored on multibyte
      expect(applyModifiers(up, alt: true), _b([0x1b, 0x1b, 0x5b, 0x41]));
    });
  });

  group('StickyModifiers state machine', () {
    test('cycles inactive → armed → locked → inactive', () {
      final m = StickyModifiers();
      expect(m.ctrl, StickyLevel.inactive);
      m.toggleCtrl();
      expect(m.ctrl, StickyLevel.armed);
      m.toggleCtrl();
      expect(m.ctrl, StickyLevel.locked);
      m.toggleCtrl();
      expect(m.ctrl, StickyLevel.inactive);
    });

    test('consumeArmed clears armed but keeps locked', () {
      final m = StickyModifiers()
        ..toggleCtrl() // armed
        ..toggleAlt()
        ..toggleAlt(); // locked
      m.consumeArmed();
      expect(m.ctrl, StickyLevel.inactive);
      expect(m.alt, StickyLevel.locked);
    });
  });
}
