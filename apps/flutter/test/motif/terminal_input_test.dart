import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_input.dart';

TerminalKeyRoute _classify({
  required LogicalKeyboardKey key,
  String? text,
  bool shift = false,
  bool control = false,
  bool alt = false,
  bool meta = false,
  bool pressOrRepeat = true,
  required bool attached,
}) {
  return classifyTerminalKey(
    logicalKey: key,
    resolvedText: text,
    shift: shift,
    control: control,
    alt: alt,
    meta: meta,
    isPressOrRepeat: pressOrRepeat,
    textInputAttached: attached,
  );
}

void main() {
  group('terminalInputModeFor', () {
    test('maps each platform', () {
      expect(
        terminalInputModeFor(TargetPlatform.iOS, isWeb: false),
        TerminalInputMode.mobile,
      );
      expect(
        terminalInputModeFor(TargetPlatform.android, isWeb: false),
        TerminalInputMode.mobile,
      );
      for (final p in [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(terminalInputModeFor(p, isWeb: false), TerminalInputMode.desktop);
      }
      // web wins regardless of underlying platform.
      expect(
        terminalInputModeFor(TargetPlatform.macOS, isWeb: true),
        TerminalInputMode.web,
      );
    });

    test('mode properties', () {
      expect(TerminalInputMode.desktop.attachesTextInput, isTrue);
      expect(TerminalInputMode.desktop.usesSoftKeyboard, isFalse);
      expect(TerminalInputMode.mobile.attachesTextInput, isTrue);
      expect(TerminalInputMode.mobile.usesSoftKeyboard, isTrue);
      expect(TerminalInputMode.web.attachesTextInput, isFalse);
      expect(TerminalInputMode.web.usesSoftKeyboard, isFalse);
    });
  });

  group('classifyTerminalKey', () {
    test('plain printable text is owned by the IME when attached', () {
      final r = _classify(key: LogicalKeyboardKey.keyA, text: 'a', attached: true);
      expect(r.kind, TerminalKeyRouteKind.deferToTextInput);
    });

    test('plain printable text is emitted directly when no IME', () {
      final r =
          _classify(key: LogicalKeyboardKey.keyA, text: 'a', attached: false);
      expect(r.kind, TerminalKeyRouteKind.sendBytes);
      expect(r.bytes, [0x61]);
    });

    test('Ctrl+key sends a control code and never defers', () {
      final r = _classify(
        key: LogicalKeyboardKey.keyA,
        text: 'a',
        control: true,
        attached: true,
      );
      expect(r.kind, TerminalKeyRouteKind.sendBytes);
      expect(r.bytes, [0x01]);
    });

    test('Alt+text is ESC-prefixed and bypasses the IME', () {
      final r = _classify(
        key: LogicalKeyboardKey.keyA,
        text: 'a',
        alt: true,
        attached: true,
      );
      expect(r.kind, TerminalKeyRouteKind.sendBytes);
      expect(r.bytes, [0x1b, 0x61]);
    });

    test('plain Enter defers to the IME when attached (no double newline)', () {
      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
      ]) {
        final r = _classify(key: key, attached: true);
        expect(r.kind, TerminalKeyRouteKind.deferToTextInput, reason: '$key');
      }
    });

    test('plain Enter goes to ghostty when no IME is attached', () {
      final r = _classify(key: LogicalKeyboardKey.enter, attached: false);
      expect(r.kind, TerminalKeyRouteKind.encodeViaGhostty);
    });

    test('modified Enter stays on the key path even with an IME', () {
      for (final mod in ['ctrl', 'alt', 'meta']) {
        final r = _classify(
          key: LogicalKeyboardKey.enter,
          control: mod == 'ctrl',
          alt: mod == 'alt',
          meta: mod == 'meta',
          attached: true,
        );
        expect(r.kind, TerminalKeyRouteKind.encodeViaGhostty, reason: mod);
      }
    });

    test('special keys go to the ghostty encoder', () {
      final r =
          _classify(key: LogicalKeyboardKey.arrowUp, text: null, attached: true);
      expect(r.kind, TerminalKeyRouteKind.encodeViaGhostty);
    });

    test('key releases route to ghostty (no text/control emission)', () {
      final r = _classify(
        key: LogicalKeyboardKey.keyA,
        text: null,
        pressOrRepeat: false,
        attached: true,
      );
      expect(r.kind, TerminalKeyRouteKind.encodeViaGhostty);
    });
  });
}
