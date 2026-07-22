import 'dart:convert';

import 'package:flutter/services.dart';

import 'keyboard_chars.dart';

/// Stable identifiers persisted by Quick Commands.
abstract final class TerminalKeyIds {
  static const escape = 'escape';
  static const tab = 'tab';
  static const enter = 'enter';
  static const numpadEnter = 'numpadEnter';
  static const space = 'space';
  static const backspace = 'backspace';
  static const delete = 'delete';
  static const insert = 'insert';
  static const arrowUp = 'arrowUp';
  static const arrowDown = 'arrowDown';
  static const arrowLeft = 'arrowLeft';
  static const arrowRight = 'arrowRight';
  static const home = 'home';
  static const end = 'end';
  static const pageUp = 'pageUp';
  static const pageDown = 'pageDown';
  static const f1 = 'f1';
  static const f2 = 'f2';
  static const f3 = 'f3';
  static const f4 = 'f4';
  static const f5 = 'f5';
  static const f6 = 'f6';
  static const f7 = 'f7';
  static const f8 = 'f8';
  static const f9 = 'f9';
  static const f10 = 'f10';
  static const f11 = 'f11';
  static const f12 = 'f12';

  static String character(String character) => 'char:$character';
}

/// A semantic key understood by both the native and WebAssembly Ghostty
/// encoders. [ghosttyKey] mirrors the public C API `GhosttyKey` value because
/// the Web build cannot import the `dart:ffi` generated enum. Native tests
/// compare the entire catalog with that generated enum to catch ABI drift.
class TerminalKeySpec {
  const TerminalKeySpec({
    required this.id,
    required this.logicalKey,
    required this.ghosttyKey,
    required this.legacyBytes,
    this.character,
    this.implicitShift = false,
  });

  final String id;
  final LogicalKeyboardKey logicalKey;
  final int ghosttyKey;
  final List<int> legacyBytes;

  /// Printable character selected in the key picker, if this is a writing key.
  final String? character;

  /// Shift is part of the selected key itself (`!`, `@`, `{`, …).
  final bool implicitShift;

  int get unshiftedCodepoint => logicalKeyUnshiftedCodepoint(logicalKey);

  String? textFor({required bool shift}) => logicalKeyEventCharacter(
    logicalKey,
    character,
    shift: shift || implicitShift,
  );
}

const _specialKeySpecs = <TerminalKeySpec>[
  TerminalKeySpec(
    id: TerminalKeyIds.escape,
    logicalKey: LogicalKeyboardKey.escape,
    ghosttyKey: 120,
    legacyBytes: [0x1b],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.tab,
    logicalKey: LogicalKeyboardKey.tab,
    ghosttyKey: 64,
    legacyBytes: [0x09],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.enter,
    logicalKey: LogicalKeyboardKey.enter,
    ghosttyKey: 58,
    legacyBytes: [0x0d],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.numpadEnter,
    logicalKey: LogicalKeyboardKey.numpadEnter,
    ghosttyKey: 97,
    legacyBytes: [0x0d],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.space,
    logicalKey: LogicalKeyboardKey.space,
    ghosttyKey: 63,
    legacyBytes: [0x20],
    character: ' ',
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.backspace,
    logicalKey: LogicalKeyboardKey.backspace,
    ghosttyKey: 53,
    legacyBytes: [0x7f],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.delete,
    logicalKey: LogicalKeyboardKey.delete,
    ghosttyKey: 68,
    legacyBytes: [0x1b, 0x5b, 0x33, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.insert,
    logicalKey: LogicalKeyboardKey.insert,
    ghosttyKey: 72,
    legacyBytes: [0x1b, 0x5b, 0x32, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.arrowUp,
    logicalKey: LogicalKeyboardKey.arrowUp,
    ghosttyKey: 78,
    legacyBytes: [0x1b, 0x5b, 0x41],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.arrowDown,
    logicalKey: LogicalKeyboardKey.arrowDown,
    ghosttyKey: 75,
    legacyBytes: [0x1b, 0x5b, 0x42],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.arrowLeft,
    logicalKey: LogicalKeyboardKey.arrowLeft,
    ghosttyKey: 76,
    legacyBytes: [0x1b, 0x5b, 0x44],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.arrowRight,
    logicalKey: LogicalKeyboardKey.arrowRight,
    ghosttyKey: 77,
    legacyBytes: [0x1b, 0x5b, 0x43],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.home,
    logicalKey: LogicalKeyboardKey.home,
    ghosttyKey: 71,
    legacyBytes: [0x1b, 0x5b, 0x48],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.end,
    logicalKey: LogicalKeyboardKey.end,
    ghosttyKey: 69,
    legacyBytes: [0x1b, 0x5b, 0x46],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.pageUp,
    logicalKey: LogicalKeyboardKey.pageUp,
    ghosttyKey: 74,
    legacyBytes: [0x1b, 0x5b, 0x35, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.pageDown,
    logicalKey: LogicalKeyboardKey.pageDown,
    ghosttyKey: 73,
    legacyBytes: [0x1b, 0x5b, 0x36, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f1,
    logicalKey: LogicalKeyboardKey.f1,
    ghosttyKey: 121,
    legacyBytes: [0x1b, 0x4f, 0x50],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f2,
    logicalKey: LogicalKeyboardKey.f2,
    ghosttyKey: 122,
    legacyBytes: [0x1b, 0x4f, 0x51],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f3,
    logicalKey: LogicalKeyboardKey.f3,
    ghosttyKey: 123,
    legacyBytes: [0x1b, 0x4f, 0x52],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f4,
    logicalKey: LogicalKeyboardKey.f4,
    ghosttyKey: 124,
    legacyBytes: [0x1b, 0x4f, 0x53],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f5,
    logicalKey: LogicalKeyboardKey.f5,
    ghosttyKey: 125,
    legacyBytes: [0x1b, 0x5b, 0x31, 0x35, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f6,
    logicalKey: LogicalKeyboardKey.f6,
    ghosttyKey: 126,
    legacyBytes: [0x1b, 0x5b, 0x31, 0x37, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f7,
    logicalKey: LogicalKeyboardKey.f7,
    ghosttyKey: 127,
    legacyBytes: [0x1b, 0x5b, 0x31, 0x38, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f8,
    logicalKey: LogicalKeyboardKey.f8,
    ghosttyKey: 128,
    legacyBytes: [0x1b, 0x5b, 0x31, 0x39, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f9,
    logicalKey: LogicalKeyboardKey.f9,
    ghosttyKey: 129,
    legacyBytes: [0x1b, 0x5b, 0x32, 0x30, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f10,
    logicalKey: LogicalKeyboardKey.f10,
    ghosttyKey: 130,
    legacyBytes: [0x1b, 0x5b, 0x32, 0x31, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f11,
    logicalKey: LogicalKeyboardKey.f11,
    ghosttyKey: 131,
    legacyBytes: [0x1b, 0x5b, 0x32, 0x33, 0x7e],
  ),
  TerminalKeySpec(
    id: TerminalKeyIds.f12,
    logicalKey: LogicalKeyboardKey.f12,
    ghosttyKey: 132,
    legacyBytes: [0x1b, 0x5b, 0x32, 0x34, 0x7e],
  ),
];

final _writingKeys =
    <
      ({
        String unshifted,
        String shifted,
        LogicalKeyboardKey logicalKey,
        int ghosttyKey,
      })
    >[
      (
        unshifted: '`',
        shifted: '~',
        logicalKey: LogicalKeyboardKey.backquote,
        ghosttyKey: 1,
      ),
      (
        unshifted: r'\',
        shifted: '|',
        logicalKey: LogicalKeyboardKey.backslash,
        ghosttyKey: 2,
      ),
      (
        unshifted: '[',
        shifted: '{',
        logicalKey: LogicalKeyboardKey.bracketLeft,
        ghosttyKey: 3,
      ),
      (
        unshifted: ']',
        shifted: '}',
        logicalKey: LogicalKeyboardKey.bracketRight,
        ghosttyKey: 4,
      ),
      (
        unshifted: ',',
        shifted: '<',
        logicalKey: LogicalKeyboardKey.comma,
        ghosttyKey: 5,
      ),
      (
        unshifted: '0',
        shifted: ')',
        logicalKey: LogicalKeyboardKey.digit0,
        ghosttyKey: 6,
      ),
      (
        unshifted: '1',
        shifted: '!',
        logicalKey: LogicalKeyboardKey.digit1,
        ghosttyKey: 7,
      ),
      (
        unshifted: '2',
        shifted: '@',
        logicalKey: LogicalKeyboardKey.digit2,
        ghosttyKey: 8,
      ),
      (
        unshifted: '3',
        shifted: '#',
        logicalKey: LogicalKeyboardKey.digit3,
        ghosttyKey: 9,
      ),
      (
        unshifted: '4',
        shifted: r'$',
        logicalKey: LogicalKeyboardKey.digit4,
        ghosttyKey: 10,
      ),
      (
        unshifted: '5',
        shifted: '%',
        logicalKey: LogicalKeyboardKey.digit5,
        ghosttyKey: 11,
      ),
      (
        unshifted: '6',
        shifted: '^',
        logicalKey: LogicalKeyboardKey.digit6,
        ghosttyKey: 12,
      ),
      (
        unshifted: '7',
        shifted: '&',
        logicalKey: LogicalKeyboardKey.digit7,
        ghosttyKey: 13,
      ),
      (
        unshifted: '8',
        shifted: '*',
        logicalKey: LogicalKeyboardKey.digit8,
        ghosttyKey: 14,
      ),
      (
        unshifted: '9',
        shifted: '(',
        logicalKey: LogicalKeyboardKey.digit9,
        ghosttyKey: 15,
      ),
      (
        unshifted: '=',
        shifted: '+',
        logicalKey: LogicalKeyboardKey.equal,
        ghosttyKey: 16,
      ),
      for (var i = 0; i < 26; i++)
        (
          unshifted: String.fromCharCode(0x61 + i),
          shifted: String.fromCharCode(0x41 + i),
          logicalKey: <LogicalKeyboardKey>[
            LogicalKeyboardKey.keyA,
            LogicalKeyboardKey.keyB,
            LogicalKeyboardKey.keyC,
            LogicalKeyboardKey.keyD,
            LogicalKeyboardKey.keyE,
            LogicalKeyboardKey.keyF,
            LogicalKeyboardKey.keyG,
            LogicalKeyboardKey.keyH,
            LogicalKeyboardKey.keyI,
            LogicalKeyboardKey.keyJ,
            LogicalKeyboardKey.keyK,
            LogicalKeyboardKey.keyL,
            LogicalKeyboardKey.keyM,
            LogicalKeyboardKey.keyN,
            LogicalKeyboardKey.keyO,
            LogicalKeyboardKey.keyP,
            LogicalKeyboardKey.keyQ,
            LogicalKeyboardKey.keyR,
            LogicalKeyboardKey.keyS,
            LogicalKeyboardKey.keyT,
            LogicalKeyboardKey.keyU,
            LogicalKeyboardKey.keyV,
            LogicalKeyboardKey.keyW,
            LogicalKeyboardKey.keyX,
            LogicalKeyboardKey.keyY,
            LogicalKeyboardKey.keyZ,
          ][i],
          ghosttyKey: 20 + i,
        ),
      (
        unshifted: '-',
        shifted: '_',
        logicalKey: LogicalKeyboardKey.minus,
        ghosttyKey: 46,
      ),
      (
        unshifted: '.',
        shifted: '>',
        logicalKey: LogicalKeyboardKey.period,
        ghosttyKey: 47,
      ),
      (
        unshifted: "'",
        shifted: '"',
        logicalKey: LogicalKeyboardKey.quote,
        ghosttyKey: 48,
      ),
      (
        unshifted: ';',
        shifted: ':',
        logicalKey: LogicalKeyboardKey.semicolon,
        ghosttyKey: 49,
      ),
      (
        unshifted: '/',
        shifted: '?',
        logicalKey: LogicalKeyboardKey.slash,
        ghosttyKey: 50,
      ),
    ];

TerminalKeySpec _characterSpec(
  String character,
  ({
    String unshifted,
    String shifted,
    LogicalKeyboardKey logicalKey,
    int ghosttyKey,
  })
  key, {
  required bool implicitShift,
}) => TerminalKeySpec(
  id: TerminalKeyIds.character(character),
  logicalKey: key.logicalKey,
  ghosttyKey: key.ghosttyKey,
  legacyBytes: character.codeUnits,
  character: character,
  implicitShift: implicitShift,
);

final List<TerminalKeySpec> terminalKeySpecs = <TerminalKeySpec>[
  ..._specialKeySpecs,
  for (final key in _writingKeys) ...[
    _characterSpec(key.unshifted, key, implicitShift: false),
    if (key.shifted != key.unshifted)
      _characterSpec(key.shifted, key, implicitShift: true),
  ],
];

final Map<String, TerminalKeySpec> _terminalKeyById = {
  for (final key in terminalKeySpecs) key.id: key,
};

final Map<LogicalKeyboardKey, TerminalKeySpec> _terminalKeyByLogicalKey = {
  for (final key in terminalKeySpecs)
    if (!key.implicitShift) key.logicalKey: key,
};

TerminalKeySpec? terminalKeySpecForId(String? id) =>
    id == null ? null : _terminalKeyById[id];

TerminalKeySpec? terminalKeySpecForCharacter(String character) =>
    _terminalKeyById[TerminalKeyIds.character(character)];

/// Resolve a Flutter hardware key to the normalized key understood by Ghostty.
/// Unicode logical keys such as `LogicalKeyboardKey.exclamation` are folded
/// back to their physical US-layout key while preserving their character text.
TerminalKeySpec? terminalKeySpecForLogicalKey(
  LogicalKeyboardKey logicalKey, {
  String? character,
}) {
  final resolvedCharacter = character?.isNotEmpty == true
      ? character
      : logicalKeyUnicodeCharacter(logicalKey);
  final known = _terminalKeyByLogicalKey[logicalKey];
  if (known != null) return known;
  if (resolvedCharacter != null) {
    final writing = terminalKeySpecForCharacter(resolvedCharacter);
    if (writing != null) return writing;
  }
  if (resolvedCharacter != null && isPrintableTerminalText(resolvedCharacter)) {
    // Some browser layouts report a Unicode logical key without a W3C
    // physical-key equivalent. Ghostty can still encode its UTF-8 text using
    // GHOSTTY_KEY_UNIDENTIFIED.
    return TerminalKeySpec(
      id: 'transient:${logicalKey.keyId}',
      logicalKey: logicalKey,
      ghosttyKey: 0,
      legacyBytes: utf8.encode(resolvedCharacter),
      character: resolvedCharacter,
    );
  }
  return null;
}

class LegacyTerminalKeyMatch {
  const LegacyTerminalKeyMatch(
    this.keyId, {
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });

  final String keyId;
  final bool ctrl;
  final bool alt;
  final bool shift;
}

/// Interpret bytes produced by the old key picker. This is only for migration;
/// runtime input must never derive a key sequence from these legacy bytes.
LegacyTerminalKeyMatch? legacyTerminalKeyForBytes(List<int> bytes) {
  if (_bytesEqual(bytes, const [0x03])) {
    return LegacyTerminalKeyMatch(TerminalKeyIds.character('c'), ctrl: true);
  }
  if (_bytesEqual(bytes, const [0x04])) {
    return LegacyTerminalKeyMatch(TerminalKeyIds.character('d'), ctrl: true);
  }
  if (_bytesEqual(bytes, const [0x1b, 0x5b, 0x5a])) {
    return const LegacyTerminalKeyMatch(TerminalKeyIds.tab, shift: true);
  }
  for (final key in terminalKeySpecs) {
    if (_bytesEqual(bytes, key.legacyBytes)) {
      return LegacyTerminalKeyMatch(key.id);
    }
  }
  return null;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
