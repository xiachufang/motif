part of '../motif_terminal_view.dart';

extension _MotifTerminalKeyEvents on _MotifTerminalViewState {
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_initialized || _terminalError != null) {
      return KeyEventResult.ignored;
    }
    // Swallow keys while disconnected/reconnecting.
    if (!widget.motif.canInput) return KeyEventResult.ignored;
    final shiftPressed = HardwareKeyboard.instance.isShiftPressed;
    final controlPressed = HardwareKeyboard.instance.isControlPressed;
    final altPressed = HardwareKeyboard.instance.isAltPressed;
    final metaPressed = HardwareKeyboard.instance.isMetaPressed;
    if (event is KeyDownEvent &&
        _handleClipboardShortcut(
          event.logicalKey,
          shift: shiftPressed,
          control: controlPressed,
          meta: metaPressed,
        )) {
      return KeyEventResult.handled;
    }
    final GhosttyKeyAction action;
    if (event is KeyDownEvent) {
      action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS;
    } else if (event is KeyUpEvent) {
      action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_RELEASE;
    } else if (event is KeyRepeatEvent) {
      action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT;
    } else {
      return KeyEventResult.ignored;
    }
    int mods = 0;
    if (shiftPressed) mods |= 1;
    if (controlPressed) mods |= 2;
    if (altPressed) mods |= 4;
    if (metaPressed) mods |= 8;
    final controlCode = logicalKeyControlCode(
      event.logicalKey,
      shift: shiftPressed,
    );
    if (!metaPressed &&
        controlPressed &&
        controlCode != null &&
        (action == GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS ||
            action == GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT)) {
      _worker?.writeBytes(
        Uint8List.fromList(altPressed ? [0x1b, controlCode] : [controlCode]),
      );
      return KeyEventResult.handled;
    }
    final text = switch (action) {
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS ||
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT => logicalKeyEventCharacter(
        event.logicalKey,
        event.character,
        shift: shiftPressed,
      ),
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_RELEASE => null,
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_MAX_VALUE => null,
    };
    if (!metaPressed &&
        !controlPressed &&
        text != null &&
        isPrintableTerminalText(text) &&
        (action == GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS ||
            action == GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT)) {
      if (!altPressed && _textInputConnectionIsActive) {
        return KeyEventResult.ignored;
      }
      final bytes = utf8.encode(text);
      _worker?.writeBytes(
        Uint8List.fromList(altPressed ? [0x1b, ...bytes] : bytes),
      );
      return KeyEventResult.handled;
    }
    final ghosttyKey = mapFlutterKey(event.logicalKey);
    if (ghosttyKey == null) return KeyEventResult.ignored;
    _worker?.encodeKey(
      key: ghosttyKey,
      action: action,
      mods: mods,
      text: text,
      unshiftedCodepoint: logicalKeyUnshiftedCodepoint(event.logicalKey),
    );
    return KeyEventResult.handled;
  }

  bool _handleClipboardShortcut(
    LogicalKeyboardKey key, {
    required bool shift,
    required bool control,
    required bool meta,
  }) {
    final isApplePlatform =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final appleClipboard = isApplePlatform && meta && !control;
    final nonAppleClipboard = !isApplePlatform && control && shift && !meta;
    if (!appleClipboard && !nonAppleClipboard) return false;
    if (key == LogicalKeyboardKey.keyV) {
      unawaited(_pasteFromClipboard());
      return true;
    }
    if (key == LogicalKeyboardKey.keyC) {
      unawaited(_copyVisible());
      return true;
    }
    return false;
  }
}
