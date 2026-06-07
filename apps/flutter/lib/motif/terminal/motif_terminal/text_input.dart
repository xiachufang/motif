// ignore_for_file: invalid_use_of_protected_member

part of '../motif_terminal_view.dart';

extension _MotifTerminalTextInput on _MotifTerminalViewState {
  void _requestFocus({required bool showSoftKeyboard}) {
    if (!mounted || !widget.active || !_focusNode.canRequestFocus) return;
    _showSoftKeyboardOnFocus = showSoftKeyboard;
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
    if (showSoftKeyboard) _openTextInput();
  }

  void _requestFocusWithoutKeyboard() {
    _requestFocus(showSoftKeyboard: false);
  }

  void _requestFocusAndKeyboard() {
    _requestFocus(showSoftKeyboard: true);
  }

  void _toggleFocus() {
    if (!mounted || !widget.active || !_focusNode.canRequestFocus) return;
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
    if (_focusNode.hasFocus && _showSoftKeyboardOnFocus) {
      _openTextInput();
    } else {
      _closeTextInput();
    }
    _syncKeyboardLift();
    if (mounted) setState(() {});
  }

  bool get _usesSoftKeyboard =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  void _openTextInput() {
    if (!_usesSoftKeyboard || !widget.active || !_focusNode.hasFocus) return;
    // No soft keyboard while disconnected/reconnecting.
    if (!widget.motif.canInput) return;
    final existing = _textInputConnection;
    if (existing != null && existing.attached) {
      _state.scrollToBottom();
      existing.show();
      return;
    }
    _state.scrollToBottom();
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
    connection.show();
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
    }
  }

  void _writeSoftKeyboardText(String text) {
    if (!_initialized || _terminalError != null || text.isEmpty) return;
    if (!widget.motif.canInput) return;
    _state.writeToPty(
      Uint8List.fromList(utf8.encode(text.replaceAll('\n', '\r'))),
    );
  }

  void _writeSoftKeyboardBytes(List<int> bytes) {
    if (!_initialized || _terminalError != null || bytes.isEmpty) return;
    if (!widget.motif.canInput) return;
    _state.writeToPty(Uint8List.fromList(bytes));
  }
}
