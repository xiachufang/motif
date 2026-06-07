/// Sticky Ctrl/Alt/Shift state + the byte transform applied to quick-command
/// payloads. Mirrors the iOS libghostty sticky-modifier state machine
/// (inactive → armed → locked) and `applyModifiers`.
library;

import 'package:flutter/foundation.dart';

/// One modifier's activation level.
enum StickyLevel { inactive, armed, locked }

/// Advance one tap: inactive → armed → locked → inactive.
StickyLevel _nextLevel(StickyLevel l) => switch (l) {
      StickyLevel.inactive => StickyLevel.armed,
      StickyLevel.armed => StickyLevel.locked,
      StickyLevel.locked => StickyLevel.inactive,
    };

class StickyModifiers extends ChangeNotifier {
  StickyLevel ctrl = StickyLevel.inactive;
  StickyLevel alt = StickyLevel.inactive;
  StickyLevel shift = StickyLevel.inactive;

  bool get ctrlActive => ctrl != StickyLevel.inactive;
  bool get altActive => alt != StickyLevel.inactive;
  bool get shiftActive => shift != StickyLevel.inactive;

  void toggleCtrl() {
    ctrl = _nextLevel(ctrl);
    notifyListeners();
  }

  void toggleAlt() {
    alt = _nextLevel(alt);
    notifyListeners();
  }

  void toggleShift() {
    shift = _nextLevel(shift);
    notifyListeners();
  }

  /// After a key is sent, clear any *armed* (one-shot) modifiers; *locked* ones
  /// persist.
  void consumeArmed() {
    var changed = false;
    if (ctrl == StickyLevel.armed) {
      ctrl = StickyLevel.inactive;
      changed = true;
    }
    if (alt == StickyLevel.armed) {
      alt = StickyLevel.inactive;
      changed = true;
    }
    if (shift == StickyLevel.armed) {
      shift = StickyLevel.inactive;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void reset() {
    ctrl = alt = shift = StickyLevel.inactive;
    notifyListeners();
  }
}

/// Apply Ctrl/Alt/Shift to a payload, mirroring the iOS `applyModifiers`.
///
/// - Shift uppercases a single ASCII letter.
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
    if (shift && b >= 0x61 && b <= 0x7a) {
      b -= 0x20; // a–z → A–Z
    }
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
