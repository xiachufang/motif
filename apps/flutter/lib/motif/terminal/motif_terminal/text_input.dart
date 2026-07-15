// ignore_for_file: invalid_use_of_protected_member

part of '../motif_terminal_view.dart';

extension _MotifTerminalTextInput on _MotifTerminalViewState {
  void _onTerminalTap() {
    final selectionWasActive = _tapStartedWithSelection;
    _tapStartedWithSelection = false;
    if (!terminalTapRequestsFocus(selectionActive: selectionWasActive)) return;
    _toggleFocus();
  }

  void _onTerminalTapCancel() {
    _tapStartedWithSelection = false;
  }

  void _requestFocus({
    required bool showSoftKeyboard,
    TerminalFocusIntent intent = TerminalFocusIntent.keyboardInput,
  }) {
    if (!mounted || !widget.active || !_focusNode.canRequestFocus) return;
    _showSoftKeyboardOnFocus = showSoftKeyboard;
    final alreadyFocused = _focusNode.hasFocus;
    if (!alreadyFocused) {
      // requestFocus may notify synchronously or on a later frame. Preserve the
      // caller's intent for _onFocusChanged either way.
      _revealBottomOnNextFocus = intent.revealBottom;
      _focusNode.requestFocus();
    }
    if (alreadyFocused &&
        _usesTextInputClient &&
        (!_usesSoftKeyboard || showSoftKeyboard)) {
      _openTextInput(
        showKeyboard: showSoftKeyboard,
        revealBottom: intent.revealBottom,
      );
    }
  }

  void _requestFocusWithoutKeyboard({
    TerminalFocusIntent intent = TerminalFocusIntent.keyboardInput,
  }) {
    _requestFocus(showSoftKeyboard: false, intent: intent);
  }

  void _requestFocusAndKeyboard() {
    _requestFocus(showSoftKeyboard: true);
  }

  void _toggleFocus() {
    if (!mounted || !widget.active || !_focusNode.canRequestFocus) return;
    if (!_usesSoftKeyboard) {
      _requestFocusWithoutKeyboard();
      return;
    }
    final connection = _textInputConnection;
    if (_focusNode.hasFocus && connection != null && connection.attached) {
      _showSoftKeyboardOnFocus = false;
      _focusNode.unfocus();
      _closeTextInput();
      return;
    }
    _requestFocusAndKeyboard();
  }

  void _onFocusChanged() {
    final revealBottom = _revealBottomOnNextFocus;
    _revealBottomOnNextFocus = true;
    if (_focusNode.hasFocus &&
        _usesTextInputClient &&
        (!_usesSoftKeyboard || _showSoftKeyboardOnFocus)) {
      _openTextInput(
        showKeyboard: _showSoftKeyboardOnFocus,
        revealBottom: revealBottom,
      );
    } else {
      _closeTextInput();
    }
    if (!_focusNode.hasFocus) {
      _hostShortcutKeys.clear();
    }
    _syncKeyboardLift();
    if (mounted) setState(() {});
  }

  /// Single source of truth for the desktop/mobile input split.
  TerminalInputMode get _inputMode =>
      terminalInputModeFor(defaultTargetPlatform);

  bool get _usesSoftKeyboard => _inputMode.usesSoftKeyboard;

  bool get _usesTextInputClient => _inputMode.attachesTextInput;

  bool get _textInputConnectionIsActive =>
      _textInputConnection?.attached ?? false;

  bool get _textInputHasComposing {
    final composing = _textInputValue.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  void _openTextInput({
    required bool showKeyboard,
    required bool revealBottom,
  }) {
    if (!_usesTextInputClient || !widget.active || !_focusNode.hasFocus) return;
    // No soft keyboard while disconnected/reconnecting.
    if (!widget.motif.canInput) return;
    final existing = _textInputConnection;
    if (existing != null && existing.attached) {
      if (revealBottom) _worker?.scrollToBottom();
      _syncImeRect();
      _scheduleImeRectSync();
      if (showKeyboard || !_usesSoftKeyboard) existing.show();
      return;
    }
    if (revealBottom) _worker?.scrollToBottom();
    // Mobile gets a plain text keyboard so iOS exposes the language switch and
    // CJK IMEs are reachable; desktop keeps the shell-friendly config.
    final connection = TextInput.attach(
      this,
      _usesSoftKeyboard
          ? terminalSoftKeyboardInputConfiguration
          : terminalTextInputConfiguration,
    );
    _textInputConnection = connection;
    connection.setEditingState(_textInputValue);
    _syncImeRect();
    _scheduleImeRectSync();
    if (showKeyboard || !_usesSoftKeyboard) connection.show();
  }

  void _closeTextInput() {
    final connection = _textInputConnection;
    if (connection != null && connection.attached) {
      connection.close();
    }
    _textInputConnection = null;
  }

  void _resetTextInputValue() {
    _textInputValue = _MotifTerminalViewState._softKeyboardValue;
    _setComposingText(null);
    final connection = _textInputConnection;
    if (connection != null && connection.attached) {
      connection.setEditingState(_textInputValue);
      _scheduleImeRectSync();
    }
  }

  /// Update the inline IME composition text and repaint if it changed.
  void _setComposingText(String? text) {
    if (_composingText == text) return;
    _composingText = text;
    if (mounted) setState(() {});
  }

  void _scheduleImeRectSync() {
    if (_imeRectSyncScheduled || !mounted) return;
    _imeRectSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _imeRectSyncScheduled = false;
      if (mounted) _syncImeRect();
    });
  }

  void _syncImeRect() {
    final connection = _textInputConnection;
    if (connection == null || !connection.attached) return;
    final surfaceContext = _terminalSurfaceKey.currentContext;
    final renderObject = surfaceContext?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        renderObject.size.isEmpty) {
      return;
    }

    connection.setEditableSizeAndTransform(
      renderObject.size,
      renderObject.getTransformTo(null),
    );
    final rect = _cursorInputRect(renderObject.size);
    connection.setComposingRect(rect);
    connection.setCaretRect(rect);
  }

  Rect _cursorInputRect(Size surfaceSize) {
    final cellWidth = _cellWidth <= 0 ? 1.0 : _cellWidth;
    final cellHeight = _cellHeight <= 0 ? 1.0 : _cellHeight;
    final cursor = _lastCursorSnapshot;
    final cursorWidth = cellWidth * (cursor?.widthCells ?? 1);
    final cursorX = cursor != null && cursor.inViewport ? cursor.x : 0;
    final cursorY = cursor != null && cursor.inViewport
        ? cursor.y
        : (_rows - 1).clamp(0, 1000);
    final maxLeft = (surfaceSize.width - cursorWidth)
        .clamp(0.0, double.infinity)
        .toDouble();
    final maxTop = (surfaceSize.height - cellHeight)
        .clamp(0.0, double.infinity)
        .toDouble();
    final left = (widget.padding + cursorX * cellWidth)
        .clamp(0.0, maxLeft)
        .toDouble();
    final top = (widget.padding + cursorY * cellHeight)
        .clamp(0.0, maxTop)
        .toDouble();
    return Rect.fromLTWH(left, top, cursorWidth, cellHeight);
  }

  void _writeSoftKeyboardText(String text) {
    if (!_initialized || _terminalError != null || text.isEmpty) return;
    if (!widget.motif.canInput) return;
    _clearTerminalSelection();
    _worker?.writeBytes(
      Uint8List.fromList(utf8.encode(text.replaceAll('\n', '\r'))),
    );
  }

  void _writeSoftKeyboardBytes(List<int> bytes) {
    if (!_initialized || _terminalError != null || bytes.isEmpty) return;
    if (!widget.motif.canInput) return;
    _clearTerminalSelection();
    _worker?.writeBytes(Uint8List.fromList(bytes));
  }

  Future<void> _pasteFromClipboard() async {
    if (!_initialized || _terminalError != null || !widget.motif.canInput) {
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) return;
    _clearTerminalSelection();
    _worker?.writeBytes(bracketedPasteBytes(text));
  }
}
