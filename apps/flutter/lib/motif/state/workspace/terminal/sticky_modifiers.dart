/// Sticky Ctrl/Alt/Shift state + the byte transform applied to quick-command
/// payloads. Mirrors the iOS libghostty sticky-modifier state machine
/// (inactive → armed → locked) and `applyModifiers`.
library;

import 'dart:typed_data';

import 'package:flutter_observation/flutter_observation.dart';

import '../../../terminal/keyboard_chars.dart';

part 'sticky_modifiers.g.dart';

/// One modifier's activation level.
enum StickyLevel { inactive, armed, locked }

/// Advance one tap: inactive → armed → locked → inactive.
StickyLevel _nextLevel(StickyLevel l) => switch (l) {
  StickyLevel.inactive => StickyLevel.armed,
  StickyLevel.armed => StickyLevel.locked,
  StickyLevel.locked => StickyLevel.inactive,
};

@ObservableModel()
class StickyModifiers extends _$StickyModifiers {
  StickyModifiers({
    StickyLevel ctrl = StickyLevel.inactive,
    StickyLevel alt = StickyLevel.inactive,
    StickyLevel shift = StickyLevel.inactive,
  }) : super(ctrl, alt, shift);

  bool get ctrlActive => ctrl != StickyLevel.inactive;
  bool get altActive => alt != StickyLevel.inactive;
  bool get shiftActive => shift != StickyLevel.inactive;

  void toggleCtrl() {
    ctrl = _nextLevel(ctrl);
  }

  void toggleAlt() {
    alt = _nextLevel(alt);
  }

  void toggleShift() {
    shift = _nextLevel(shift);
  }

  /// After a key is sent, clear any *armed* (one-shot) modifiers; *locked* ones
  /// persist.
  void consumeArmed() {
    observationTransaction(() {
      if (ctrl == StickyLevel.armed) ctrl = StickyLevel.inactive;
      if (alt == StickyLevel.armed) alt = StickyLevel.inactive;
      if (shift == StickyLevel.armed) shift = StickyLevel.inactive;
    });
  }

  void reset() {
    observationTransaction(() {
      ctrl = StickyLevel.inactive;
      alt = StickyLevel.inactive;
      shift = StickyLevel.inactive;
    });
  }
}

/// Apply Ctrl/Alt/Shift to an explicitly raw byte payload.
///
/// Semantic key commands bypass this helper and let Ghostty encode modifiers
/// against the active terminal protocol and modes.
///
/// - Shift maps a single US-ASCII printable key to its shifted form.
/// - Ctrl maps a single ASCII char to its control code (`c & 0x1f`).
/// - Alt prefixes the result with ESC (0x1b).
///
/// Multi-byte payloads (e.g. arrow-key escape sequences) are returned unchanged
/// except for an Alt ESC prefix, matching the terminal convention.
Uint8List applyModifiers(
  Uint8List payload, {
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
}) {
  var bytes = List<int>.from(payload);

  if (bytes.length == 1) {
    var b = bytes[0];
    if (shift) b = shiftAsciiCodeUnit(b);
    if (ctrl) {
      b = b & 0x1f;
    }
    bytes = [b];
  }

  if (alt) {
    bytes = [0x1b, ...bytes];
  }
  return Uint8List.fromList(bytes);
}
