import 'package:flutter/services.dart';

String? logicalKeyCharacter(LogicalKeyboardKey key, {required bool shift}) {
  final chars = _printableKeyChars[key];
  if (chars == null) return null;
  return shift ? chars.shifted : chars.unshifted;
}

String? logicalKeyEventCharacter(
  LogicalKeyboardKey key,
  String? character, {
  required bool shift,
}) {
  final chars = _printableKeyChars[key];
  if (character != null && character.isNotEmpty) {
    if (shift && chars != null && character == chars.unshifted) {
      return chars.shifted;
    }
    return character;
  }
  if (chars == null) return null;
  return shift ? chars.shifted : chars.unshifted;
}

int logicalKeyUnshiftedCodepoint(LogicalKeyboardKey key) {
  final chars = _printableKeyChars[key];
  return chars == null ? 0 : chars.unshifted.codeUnitAt(0);
}

int? logicalKeyControlCode(LogicalKeyboardKey key, {required bool shift}) {
  final chars = _printableKeyChars[key];
  if (chars == null) return null;
  for (final ch in [
    shift ? chars.shifted : chars.unshifted,
    chars.unshifted,
    chars.shifted,
  ]) {
    if (ch.length != 1) continue;
    final cp = ch.codeUnitAt(0);
    final upper = (cp >= 0x61 && cp <= 0x7a) ? cp - 0x20 : cp;
    if (upper >= 0x40 && upper <= 0x5f) return upper & 0x1f;
    if (upper == 0x3f) return 0x7f;
  }
  return null;
}

int shiftAsciiCodeUnit(int codeUnit) {
  return _shiftedAsciiCodeUnits[codeUnit] ?? codeUnit;
}

final Map<LogicalKeyboardKey, ({String unshifted, String shifted})>
_printableKeyChars = {
  LogicalKeyboardKey.keyA: (unshifted: 'a', shifted: 'A'),
  LogicalKeyboardKey.keyB: (unshifted: 'b', shifted: 'B'),
  LogicalKeyboardKey.keyC: (unshifted: 'c', shifted: 'C'),
  LogicalKeyboardKey.keyD: (unshifted: 'd', shifted: 'D'),
  LogicalKeyboardKey.keyE: (unshifted: 'e', shifted: 'E'),
  LogicalKeyboardKey.keyF: (unshifted: 'f', shifted: 'F'),
  LogicalKeyboardKey.keyG: (unshifted: 'g', shifted: 'G'),
  LogicalKeyboardKey.keyH: (unshifted: 'h', shifted: 'H'),
  LogicalKeyboardKey.keyI: (unshifted: 'i', shifted: 'I'),
  LogicalKeyboardKey.keyJ: (unshifted: 'j', shifted: 'J'),
  LogicalKeyboardKey.keyK: (unshifted: 'k', shifted: 'K'),
  LogicalKeyboardKey.keyL: (unshifted: 'l', shifted: 'L'),
  LogicalKeyboardKey.keyM: (unshifted: 'm', shifted: 'M'),
  LogicalKeyboardKey.keyN: (unshifted: 'n', shifted: 'N'),
  LogicalKeyboardKey.keyO: (unshifted: 'o', shifted: 'O'),
  LogicalKeyboardKey.keyP: (unshifted: 'p', shifted: 'P'),
  LogicalKeyboardKey.keyQ: (unshifted: 'q', shifted: 'Q'),
  LogicalKeyboardKey.keyR: (unshifted: 'r', shifted: 'R'),
  LogicalKeyboardKey.keyS: (unshifted: 's', shifted: 'S'),
  LogicalKeyboardKey.keyT: (unshifted: 't', shifted: 'T'),
  LogicalKeyboardKey.keyU: (unshifted: 'u', shifted: 'U'),
  LogicalKeyboardKey.keyV: (unshifted: 'v', shifted: 'V'),
  LogicalKeyboardKey.keyW: (unshifted: 'w', shifted: 'W'),
  LogicalKeyboardKey.keyX: (unshifted: 'x', shifted: 'X'),
  LogicalKeyboardKey.keyY: (unshifted: 'y', shifted: 'Y'),
  LogicalKeyboardKey.keyZ: (unshifted: 'z', shifted: 'Z'),
  LogicalKeyboardKey.digit0: (unshifted: '0', shifted: ')'),
  LogicalKeyboardKey.digit1: (unshifted: '1', shifted: '!'),
  LogicalKeyboardKey.digit2: (unshifted: '2', shifted: '@'),
  LogicalKeyboardKey.digit3: (unshifted: '3', shifted: '#'),
  LogicalKeyboardKey.digit4: (unshifted: '4', shifted: r'$'),
  LogicalKeyboardKey.digit5: (unshifted: '5', shifted: '%'),
  LogicalKeyboardKey.digit6: (unshifted: '6', shifted: '^'),
  LogicalKeyboardKey.digit7: (unshifted: '7', shifted: '&'),
  LogicalKeyboardKey.digit8: (unshifted: '8', shifted: '*'),
  LogicalKeyboardKey.digit9: (unshifted: '9', shifted: '('),
  LogicalKeyboardKey.backquote: (unshifted: '`', shifted: '~'),
  LogicalKeyboardKey.backslash: (unshifted: r'\', shifted: '|'),
  LogicalKeyboardKey.bracketLeft: (unshifted: '[', shifted: '{'),
  LogicalKeyboardKey.bracketRight: (unshifted: ']', shifted: '}'),
  LogicalKeyboardKey.comma: (unshifted: ',', shifted: '<'),
  LogicalKeyboardKey.equal: (unshifted: '=', shifted: '+'),
  LogicalKeyboardKey.minus: (unshifted: '-', shifted: '_'),
  LogicalKeyboardKey.period: (unshifted: '.', shifted: '>'),
  LogicalKeyboardKey.quote: (unshifted: "'", shifted: '"'),
  LogicalKeyboardKey.semicolon: (unshifted: ';', shifted: ':'),
  LogicalKeyboardKey.slash: (unshifted: '/', shifted: '?'),
  LogicalKeyboardKey.space: (unshifted: ' ', shifted: ' '),
};

final Map<int, int> _shiftedAsciiCodeUnits = {
  for (final chars in _printableKeyChars.values)
    if (chars.unshifted.length == 1 && chars.shifted.length == 1)
      chars.unshifted.codeUnitAt(0): chars.shifted.codeUnitAt(0),
};
