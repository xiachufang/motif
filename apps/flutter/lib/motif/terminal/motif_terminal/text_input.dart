// ignore_for_file: invalid_use_of_protected_member

part of '../motif_terminal_view.dart';

extension _MotifTerminalTextInput on _MotifTerminalViewState {
  void _requestFocus({required bool showSoftKeyboard}) {
    if (!mounted || !widget.active || !_focusNode.canRequestFocus) return;
    _showSoftKeyboardOnFocus = showSoftKeyboard;
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
    if (_usesTextInputClient && (!_usesSoftKeyboard || showSoftKeyboard)) {
      _openTextInput(showKeyboard: showSoftKeyboard);
    }
  }

  void _requestFocusWithoutKeyboard() {
    _requestFocus(showSoftKeyboard: false);
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
    if (_focusNode.hasFocus &&
        _usesTextInputClient &&
        (!_usesSoftKeyboard || _showSoftKeyboardOnFocus)) {
      _openTextInput(showKeyboard: _showSoftKeyboardOnFocus);
    } else {
      _closeTextInput();
    }
    _syncKeyboardLift();
    if (mounted) setState(() {});
  }

  bool get _usesSoftKeyboard =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  bool get _usesTextInputClient =>
      _usesSoftKeyboard ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.fuchsia;

  bool get _textInputConnectionIsActive =>
      _textInputConnection?.attached ?? false;

  void _openTextInput({required bool showKeyboard}) {
    if (!_usesTextInputClient || !widget.active || !_focusNode.hasFocus) return;
    // No soft keyboard while disconnected/reconnecting.
    if (!widget.motif.canInput) return;
    final existing = _textInputConnection;
    if (existing != null && existing.attached) {
      _worker?.scrollToBottom();
      _syncImeRect();
      _scheduleImeRectSync();
      if (showKeyboard || !_usesSoftKeyboard) existing.show();
      return;
    }
    _worker?.scrollToBottom();
    _textInputValue = _MotifTerminalViewState._softKeyboardValue;
    final connection = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.text,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        enableSuggestions: false,
        enableInteractiveSelection: false,
        enableIMEPersonalizedLearning: false,
      ),
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
    _textInputValue = _MotifTerminalViewState._softKeyboardValue;
  }

  void _resetTextInputValue() {
    _textInputValue = _MotifTerminalViewState._softKeyboardValue;
    final connection = _textInputConnection;
    if (connection != null && connection.attached) {
      connection.setEditingState(_textInputValue);
      _scheduleImeRectSync();
    }
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
    final cursorX = cursor != null && cursor.inViewport ? cursor.x : 0;
    final cursorY = cursor != null && cursor.inViewport
        ? cursor.y
        : (_rows - 1).clamp(0, 1000);
    final maxLeft = (surfaceSize.width - cellWidth)
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
    return Rect.fromLTWH(left, top, cellWidth, cellHeight);
  }

  void _writeSoftKeyboardText(String text) {
    if (!_initialized || _terminalError != null || text.isEmpty) return;
    if (!widget.motif.canInput) return;
    _worker?.writeBytes(
      Uint8List.fromList(utf8.encode(text.replaceAll('\n', '\r'))),
    );
  }

  void _writeSoftKeyboardBytes(List<int> bytes) {
    if (!_initialized || _terminalError != null || bytes.isEmpty) return;
    if (!widget.motif.canInput) return;
    _worker?.writeBytes(Uint8List.fromList(bytes));
  }

  Future<void> _pasteFromClipboard() async {
    if (!_initialized || _terminalError != null || !widget.motif.canInput) {
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) return;
    _worker?.writeBytes(bracketedPasteBytes(text));
  }
}
