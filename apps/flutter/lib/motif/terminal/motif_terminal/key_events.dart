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
    final hostShortcut = isTerminalHostShortcut(
      logicalKey: event.logicalKey,
      shift: shiftPressed,
      control: controlPressed,
      alt: altPressed,
      meta: metaPressed,
    );
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (hostShortcut) {
        _hostShortcutKeys.add(event.logicalKey);
        return KeyEventResult.ignored;
      }
      if (_textInputCancelKeys.contains(event.logicalKey)) {
        return KeyEventResult.handled;
      }
    } else if (event is KeyUpEvent) {
      if (_textInputCancelKeys.remove(event.logicalKey)) {
        return KeyEventResult.handled;
      }
      final wasHostShortcut = _hostShortcutKeys.remove(event.logicalKey);
      if (hostShortcut || wasHostShortcut) return KeyEventResult.ignored;
    }
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

    final isPressOrRepeat =
        action == GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS ||
        action == GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT;
    // Resolve the printable character once; reused for both the routing
    // decision and the ghostty encoder. Releases carry no text.
    final text = isPressOrRepeat
        ? logicalKeyEventCharacter(
            event.logicalKey,
            event.character,
            shift: shiftPressed,
          )
        : null;

    // One place decides who owns this key (see terminal_input.dart). The key
    // path emits control codes / printable text, defers plain text + plain
    // Enter to the IME when a connection owns text, and otherwise hands special
    // keys to the ghostty encoder.
    final route = classifyTerminalKey(
      logicalKey: event.logicalKey,
      resolvedText: text,
      shift: shiftPressed,
      control: controlPressed,
      alt: altPressed,
      meta: metaPressed,
      isPressOrRepeat: isPressOrRepeat,
      textInputAttached: _textInputConnectionIsActive,
      textInputComposing: _textInputHasComposing,
    );
    switch (route.kind) {
      case TerminalKeyRouteKind.deferToTextInput:
      case TerminalKeyRouteKind.ignore:
        return KeyEventResult.ignored;
      case TerminalKeyRouteKind.cancelTextInputComposition:
        if (_cancelTextInputComposition()) {
          _textInputCancelKeys.add(event.logicalKey);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case TerminalKeyRouteKind.sendBytes:
        _clearTerminalSelection();
        _worker?.writeBytes(Uint8List.fromList(route.bytes!));
        return KeyEventResult.handled;
      case TerminalKeyRouteKind.encodeViaGhostty:
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
      _clearTerminalSelection();
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
