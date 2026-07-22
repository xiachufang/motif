part of '../motif_terminal_view.dart';

extension _MotifTerminalKeyEvents on _MotifTerminalViewState {
  bool _onTerminalInput(TerminalInputEvent input) {
    if (input case TerminalPasteInput(:final bytes) when bytes.isEmpty) {
      return false;
    }
    if (input case TerminalKeyInput(
      :final keyId,
    ) when terminalKeySpecForId(keyId) == null) {
      return false;
    }
    final worker = _worker;
    if (_terminalError != null) return false;
    if (!_initialized || worker == null) {
      if (_pendingTerminalInputs.length >=
          _MotifTerminalViewState._maxPendingTerminalInputs) {
        return false;
      }
      _pendingTerminalInputs.add(input);
      return true;
    }
    _dispatchTerminalInputToWorker(worker, input);
    return true;
  }

  void _flushPendingTerminalInputs() {
    final worker = _worker;
    if (!_initialized || _terminalError != null || worker == null) return;
    final pending = List<TerminalInputEvent>.of(_pendingTerminalInputs);
    _pendingTerminalInputs.clear();
    for (final input in pending) {
      _dispatchTerminalInputToWorker(worker, input);
    }
  }

  void _dispatchTerminalInputToWorker(
    TerminalWorkerClient worker,
    TerminalInputEvent input,
  ) {
    // The queued PTY bytes may contain a mode transition (DECCKM, DECBKM,
    // bracketed paste, ...). Preserve wire order by parsing every byte already
    // received from the host before asking Ghostty to encode local input.
    _flushRemoteBytesToWorker();
    _clearTerminalSelection();
    switch (input) {
      case TerminalPasteInput(:final bytes):
        if (bytes.isEmpty) return;
        worker.encodePaste(bytes);
      case TerminalKeyInput():
        final key = terminalKeySpecForId(input.keyId);
        if (key == null) return;
        final action = switch (input.action) {
          TerminalKeyAction.release =>
            GhosttyKeyAction.GHOSTTY_KEY_ACTION_RELEASE,
          TerminalKeyAction.press => GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
          TerminalKeyAction.repeat =>
            GhosttyKeyAction.GHOSTTY_KEY_ACTION_REPEAT,
        };
        final shift = input.modifiers.shift || key.implicitShift;
        final isPressOrRepeat = input.action != TerminalKeyAction.release;
        worker.encodeKey(
          key: GhosttyKey.fromValue(key.ghosttyKey),
          action: action,
          mods: input.modifiers.ghosttyMask | (shift ? 1 : 0),
          text: isPressOrRepeat ? key.textFor(shift: shift) : null,
          unshiftedCodepoint: key.unshiftedCodepoint,
        );
    }
  }

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
    } else if (event is KeyUpEvent) {
      final wasHostShortcut = _hostShortcutKeys.remove(event.logicalKey);
      if (hostShortcut || wasHostShortcut) return KeyEventResult.ignored;
    }
    // Editing shortcuts belong to the native text client while it is
    // composing; otherwise they operate on the terminal as usual.
    if (event is KeyDownEvent &&
        !_textInputHasComposing &&
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
    // path gives an active composition exclusive ownership, otherwise emits
    // control codes / printable text, defers plain text + plain Enter to the
    // attached text client, and hands special keys to the ghostty encoder.
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
      case TerminalKeyRouteKind.sendBytes:
        _flushRemoteBytesToWorker();
        _clearTerminalSelection();
        _worker?.writeBytes(Uint8List.fromList(route.bytes!));
        return KeyEventResult.handled;
      case TerminalKeyRouteKind.encodeViaGhostty:
        final ghosttyKey = mapFlutterKey(event.logicalKey);
        if (ghosttyKey == null) return KeyEventResult.ignored;
        _flushRemoteBytesToWorker();
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
