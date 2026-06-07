/// Pure-Dart keyboard → terminal byte encoder for the web terminal (where the
/// native ghostty key encoder isn't available via FFI). Covers the common keys:
/// printable text, Enter/Tab/Esc/Backspace, arrows, Home/End/PageUp/Down/Delete,
/// and Ctrl/Alt modifiers. Mirrors xterm/VT conventions.
library;

import 'package:flutter/services.dart';

import 'keyboard_chars.dart';

class TerminalKeyMods {
  final bool ctrl;
  final bool alt;
  final bool shift;
  const TerminalKeyMods({
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });
}

/// Returns the bytes to send for a key press, or null if the key isn't handled
/// (caller should ignore it).
List<int>? encodeKeyToBytes(
  LogicalKeyboardKey key,
  String? character,
  TerminalKeyMods mods,
) {
  // Named keys first.
  final named = _namedKey(key);
  if (named != null) {
    return mods.alt ? [0x1b, ...named] : named;
  }

  // Printable character.
  final text = logicalKeyEventCharacter(key, character, shift: mods.shift);
  if (text != null && text.isNotEmpty) {
    // Ctrl+<char>: map a single ASCII letter/char to its control code.
    if (mods.ctrl && text.length == 1) {
      final cp = text.codeUnitAt(0);
      final base = (cp >= 0x61 && cp <= 0x7a) ? cp - 0x20 : cp; // upper for a-z
      final ctrlCode = base & 0x1f;
      return mods.alt ? [0x1b, ctrlCode] : [ctrlCode];
    }
    final bytes = text.codeUnits;
    return mods.alt ? [0x1b, ...bytes] : bytes;
  }
  return null;
}

List<int>? _namedKey(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    return const [0x0d];
  }
  if (key == LogicalKeyboardKey.backspace) return const [0x7f];
  if (key == LogicalKeyboardKey.tab) return const [0x09];
  if (key == LogicalKeyboardKey.escape) return const [0x1b];
  if (key == LogicalKeyboardKey.arrowUp) return const [0x1b, 0x5b, 0x41];
  if (key == LogicalKeyboardKey.arrowDown) return const [0x1b, 0x5b, 0x42];
  if (key == LogicalKeyboardKey.arrowRight) return const [0x1b, 0x5b, 0x43];
  if (key == LogicalKeyboardKey.arrowLeft) return const [0x1b, 0x5b, 0x44];
  if (key == LogicalKeyboardKey.home) return const [0x1b, 0x5b, 0x48];
  if (key == LogicalKeyboardKey.end) return const [0x1b, 0x5b, 0x46];
  if (key == LogicalKeyboardKey.delete) return const [0x1b, 0x5b, 0x33, 0x7e];
  if (key == LogicalKeyboardKey.pageUp) return const [0x1b, 0x5b, 0x35, 0x7e];
  if (key == LogicalKeyboardKey.pageDown) return const [0x1b, 0x5b, 0x36, 0x7e];
  return null;
}
