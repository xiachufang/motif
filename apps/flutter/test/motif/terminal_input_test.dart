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
  bool composing = false,
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
    textInputComposing: composing,
  );
}

void main() {
  group('terminal input configuration', () {
    test('defaults terminal text input to English-friendly settings', () {
      expect(terminalKeyboardType, TextInputType.visiblePassword);
      expect(terminalEnglishHintLocales.single.toLanguageTag(), 'en-US');
      expect(
        terminalTextInputConfiguration.inputType,
        TextInputType.visiblePassword,
      );
      expect(terminalTextInputConfiguration.autocorrect, isFalse);
      expect(terminalTextInputConfiguration.enableSuggestions, isFalse);
      expect(
        terminalTextInputConfiguration.smartDashesType,
        SmartDashesType.disabled,
      );
      expect(
        terminalTextInputConfiguration.smartQuotesType,
        SmartQuotesType.disabled,
      );
      expect(
        terminalTextInputConfiguration.hintLocales?.single.toLanguageTag(),
        'en-US',
      );
      expect(terminalTextInputConfiguration.enableInlinePrediction, isFalse);
    });

    test('soft keyboard config is English-biased but allows CJK switching', () {
      // A plain text keyboard (not visiblePassword), so iOS shows the language
      // switch and CJK IMEs are reachable...
      expect(
        terminalSoftKeyboardInputConfiguration.inputType,
        TextInputType.text,
      );
      // ...while the English locale hint only biases a fresh keyboard toward
      // English (the globe key still switches; per-tab memory restores choices).
      expect(
        terminalSoftKeyboardInputConfiguration.hintLocales?.single
            .toLanguageTag(),
        'en-US',
      );
      // ...while substitution stays off so the shell never gets altered text.
      expect(terminalSoftKeyboardInputConfiguration.autocorrect, isFalse);
      expect(terminalSoftKeyboardInputConfiguration.enableSuggestions, isFalse);
      expect(
        terminalSoftKeyboardInputConfiguration.smartDashesType,
        SmartDashesType.disabled,
      );
      expect(
        terminalSoftKeyboardInputConfiguration.smartQuotesType,
        SmartQuotesType.disabled,
      );
      expect(
        terminalSoftKeyboardInputConfiguration.enableInlinePrediction,
        isFalse,
      );
    });
  });

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
        expect(
          terminalInputModeFor(p, isWeb: false),
          TerminalInputMode.desktop,
        );
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

  group('isTerminalHostShortcut', () {
    bool host(
      LogicalKeyboardKey key, {
      bool shift = false,
      bool control = false,
      bool alt = false,
      bool meta = false,
      TargetPlatform platform = TargetPlatform.macOS,
    }) {
      return isTerminalHostShortcut(
        logicalKey: key,
        shift: shift,
        control: control,
        alt: alt,
        meta: meta,
        platform: platform,
      );
    }

    test('reserves chrome-style tab shortcuts on Apple platforms', () {
      expect(host(LogicalKeyboardKey.keyT, meta: true), isTrue);
      expect(host(LogicalKeyboardKey.keyW, meta: true), isTrue);
      expect(host(LogicalKeyboardKey.keyQ, meta: true), isTrue);
      expect(host(LogicalKeyboardKey.digit1, meta: true), isTrue);
      expect(host(LogicalKeyboardKey.digit9, meta: true), isTrue);
      expect(host(LogicalKeyboardKey.pageUp, meta: true), isTrue);
      expect(host(LogicalKeyboardKey.pageDown, meta: true), isTrue);

      expect(host(LogicalKeyboardKey.keyC, meta: true), isFalse);
      expect(host(LogicalKeyboardKey.keyT, meta: true, alt: true), isFalse);
    });

    test('reserves chrome-style tab shortcuts on control platforms', () {
      expect(
        host(
          LogicalKeyboardKey.keyT,
          control: true,
          platform: TargetPlatform.windows,
        ),
        isTrue,
      );
      expect(
        host(
          LogicalKeyboardKey.digit2,
          control: true,
          platform: TargetPlatform.linux,
        ),
        isTrue,
      );
      expect(
        host(
          LogicalKeyboardKey.keyC,
          control: true,
          platform: TargetPlatform.windows,
        ),
        isFalse,
      );
      expect(
        host(
          LogicalKeyboardKey.keyQ,
          control: true,
          platform: TargetPlatform.windows,
        ),
        isFalse,
      );
    });

    test('reserves session sidebar shortcuts', () {
      for (final key in [
        LogicalKeyboardKey.keyW,
        LogicalKeyboardKey.keyL,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyG,
      ]) {
        expect(host(key, meta: true, shift: true), isTrue, reason: '$key');
      }
    });

    test('reserves tab cycling shortcuts', () {
      expect(host(LogicalKeyboardKey.tab, control: true), isTrue);
      expect(host(LogicalKeyboardKey.tab, control: true, shift: true), isTrue);
      expect(host(LogicalKeyboardKey.arrowLeft, meta: true, alt: true), isTrue);
      expect(
        host(LogicalKeyboardKey.arrowRight, meta: true, alt: true),
        isTrue,
      );
      expect(
        host(LogicalKeyboardKey.arrowLeft, control: true, alt: true),
        isFalse,
      );
    });
  });

  group('classifyTerminalKey', () {
    test('plain printable text is owned by the IME when attached', () {
      final r = _classify(
        key: LogicalKeyboardKey.keyA,
        text: 'a',
        attached: true,
      );
      expect(r.kind, TerminalKeyRouteKind.deferToTextInput);
    });

    test('plain printable text is emitted directly when no IME', () {
      final r = _classify(
        key: LogicalKeyboardKey.keyA,
        text: 'a',
        attached: false,
      );
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

    test('active IME composition owns editing and candidate keys', () {
      for (final key in [
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.digit1,
      ]) {
        final r = _classify(key: key, attached: true, composing: true);
        expect(r.kind, TerminalKeyRouteKind.deferToTextInput, reason: '$key');
      }
    });

    test('active IME composition owns modified and control keys', () {
      for (final r in [
        _classify(
          key: LogicalKeyboardKey.keyH,
          text: 'h',
          control: true,
          attached: true,
          composing: true,
        ),
        _classify(
          key: LogicalKeyboardKey.arrowLeft,
          alt: true,
          attached: true,
          composing: true,
        ),
        _classify(
          key: LogicalKeyboardKey.space,
          shift: true,
          attached: true,
          composing: true,
        ),
        _classify(
          key: LogicalKeyboardKey.keyV,
          text: 'v',
          meta: true,
          attached: true,
          composing: true,
        ),
      ]) {
        expect(r.kind, TerminalKeyRouteKind.deferToTextInput);
      }
    });

    test('active IME composition owns key releases', () {
      final r = _classify(
        key: LogicalKeyboardKey.arrowDown,
        pressOrRepeat: false,
        attached: true,
        composing: true,
      );
      expect(r.kind, TerminalKeyRouteKind.deferToTextInput);
    });

    test('plain Escape reaches ghostty when the IME is not composing', () {
      final r = _classify(
        key: LogicalKeyboardKey.escape,
        attached: true,
        composing: false,
      );
      expect(r.kind, TerminalKeyRouteKind.encodeViaGhostty);
    });

    test('plain Backspace reaches ghostty when the IME is not composing', () {
      final r = _classify(
        key: LogicalKeyboardKey.backspace,
        attached: true,
        composing: false,
      );
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
      final r = _classify(
        key: LogicalKeyboardKey.arrowUp,
        text: null,
        attached: true,
      );
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
