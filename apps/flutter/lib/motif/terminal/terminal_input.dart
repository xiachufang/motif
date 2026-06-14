import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'keyboard_chars.dart';

/// How the terminal takes keyboard/text input on the current platform.
///
/// This is the single source of truth for the platform split that the input
/// code used to spread across several ad-hoc getters. The native terminal
/// (`motif_terminal_view.dart`) only ever runs as [desktop] or [mobile]; [web]
/// is served by a separate widget (`wasm_terminal_web.dart`).
enum TerminalInputMode {
  /// Physical keyboard is primary (macOS/Linux/Windows/Fuchsia). A Flutter
  /// `TextInput` client is attached so the platform IME can compose text
  /// (e.g. CJK) and commit it; everything else flows through the key path.
  /// No on-screen keyboard, no keyboard lift.
  desktop,

  /// The on-screen soft keyboard is primary (iOS/Android), via the `TextInput`
  /// client. The key path only serves an attached hardware keyboard's non-text
  /// keys.
  mobile,

  /// No native worker / no `TextInput` client; a pure-Dart key encoder
  /// (`web_key_encoder.dart`) is used instead.
  web,
}

/// Resolve the input mode for a platform. [isWeb] defaults to [kIsWeb].
TerminalInputMode terminalInputModeFor(
  TargetPlatform platform, {
  bool isWeb = kIsWeb,
}) {
  if (isWeb) return TerminalInputMode.web;
  return switch (platform) {
    TargetPlatform.iOS || TargetPlatform.android => TerminalInputMode.mobile,
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows ||
    TargetPlatform.fuchsia => TerminalInputMode.desktop,
  };
}

extension TerminalInputModeProps on TerminalInputMode {
  /// Whether a Flutter `TextInput` (IME) client is attached. True for desktop
  /// (composition) and mobile (soft keyboard); false on web.
  bool get attachesTextInput => this != TerminalInputMode.web;

  /// Whether an on-screen keyboard is shown and the view lifts for it. Mobile
  /// only.
  bool get usesSoftKeyboard => this == TerminalInputMode.mobile;
}

/// What the hardware-key path should do with one key event.
enum TerminalKeyRouteKind {
  /// Let the attached `TextInput`/IME own this input — the key path returns
  /// `KeyEventResult.ignored` so it isn't also emitted (the double-input bug).
  deferToTextInput,

  /// Write [TerminalKeyRoute.bytes] straight to the PTY.
  sendBytes,

  /// Hand off to the ghostty key encoder (named/special keys, modified Enter,
  /// key releases, …).
  encodeViaGhostty,

  /// Nothing to do; the key path returns `KeyEventResult.ignored`.
  ignore,
}

class TerminalKeyRoute {
  final TerminalKeyRouteKind kind;

  /// Raw bytes to write when [kind] is [TerminalKeyRouteKind.sendBytes].
  final List<int>? bytes;

  const TerminalKeyRoute._(this.kind, [this.bytes]);

  static const deferToTextInput =
      TerminalKeyRoute._(TerminalKeyRouteKind.deferToTextInput);
  static const encodeViaGhostty =
      TerminalKeyRoute._(TerminalKeyRouteKind.encodeViaGhostty);
  static const ignore = TerminalKeyRoute._(TerminalKeyRouteKind.ignore);

  factory TerminalKeyRoute.send(List<int> bytes) =>
      TerminalKeyRoute._(TerminalKeyRouteKind.sendBytes, bytes);
}

/// Decide how a hardware key event becomes terminal input — the one place that
/// states who owns what (see the contract in `docs`/the input module doc).
///
/// [resolvedText] is the already-resolved printable character for the event (or
/// null), so the caller can reuse it for the ghostty encoder. [textInputAttached]
/// is whether a `TextInput` connection is currently live; when it is, it owns
/// plain text and the plain newline (Enter), so the key path defers them.
/// [isPressOrRepeat] is false for key-up events.
///
/// Branch order is significant and mirrors a real terminal: control combos →
/// printable text → plain Enter → everything else (special keys) via ghostty.
TerminalKeyRoute classifyTerminalKey({
  required LogicalKeyboardKey logicalKey,
  required String? resolvedText,
  required bool shift,
  required bool control,
  required bool alt,
  required bool meta,
  required bool isPressOrRepeat,
  required bool textInputAttached,
}) {
  // Ctrl[+Alt]+<key> → control code (e.g. Ctrl+A → 0x01). Never deferred.
  if (isPressOrRepeat && control && !meta) {
    final code = logicalKeyControlCode(logicalKey, shift: shift);
    if (code != null) {
      return TerminalKeyRoute.send(alt ? [0x1b, code] : [code]);
    }
  }

  // Printable text. When the IME owns text (a connection is attached and Alt
  // isn't held), defer so it isn't sent twice; otherwise emit UTF-8, ESC-prefixed
  // for Alt.
  if (isPressOrRepeat && !control && !meta) {
    final text = resolvedText;
    if (text != null && isPrintableTerminalText(text)) {
      if (!alt && textInputAttached) return TerminalKeyRoute.deferToTextInput;
      final bytes = utf8.encode(text);
      return TerminalKeyRoute.send(alt ? [0x1b, ...bytes] : bytes);
    }
  }

  // Plain Enter is "text" too: when a TextInput connection owns text it also
  // owns the newline (performAction). Modified Enter keeps the key path for its
  // proper escape sequence.
  final isEnter = logicalKey == LogicalKeyboardKey.enter ||
      logicalKey == LogicalKeyboardKey.numpadEnter;
  if (isEnter && textInputAttached && !control && !alt && !meta) {
    return TerminalKeyRoute.deferToTextInput;
  }

  // Named/special keys, modified Enter, releases — the ghostty encoder.
  return TerminalKeyRoute.encodeViaGhostty;
}
