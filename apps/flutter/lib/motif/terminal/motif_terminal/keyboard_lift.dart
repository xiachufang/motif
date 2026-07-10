part of '../motif_terminal_view.dart';

extension _MotifTerminalKeyboardLift on _MotifTerminalViewState {
  void _scheduleKeyboardLiftSync() {
    if (_keyboardLiftSyncScheduled || !mounted) return;
    _keyboardLiftSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardLiftSyncScheduled = false;
      if (mounted) _syncKeyboardLift();
    });
  }

  void _syncKeyboardLift() {
    final trace = _keyboardLift();
    final lift = trace.lift;
    final previous = _keyboardLiftOffset.value;
    if ((lift - previous).abs() < 0.5) return;
    _keyboardLiftOffset.value = lift;
    _lastKeyboardLiftTrace = trace;
    _logKeyboardLift(trace, previous);
    _scheduleImeRectSync();
  }

  _KeyboardLiftTrace _keyboardLift() {
    final cursor = _lastCursorSnapshot;
    if (!_usesSoftKeyboard || !widget.active) {
      final keyboardHeight = widget.keyboardInset.value;
      final keyboardVisualLift = (keyboardHeight - _bottomViewPadding).clamp(
        0.0,
        double.infinity,
      );
      return _KeyboardLiftTrace.zero(
        reason: !_usesSoftKeyboard ? 'no-soft-keyboard' : 'inactive',
        keyboardHeight: keyboardHeight,
        keyboardVisualLift: keyboardVisualLift,
        bottomViewPadding: _bottomViewPadding,
        cursorVisible: cursor?.visible ?? false,
        cursorInViewport: cursor?.inViewport ?? false,
        focused: _focusNode.hasFocus,
        active: widget.active,
        previous: _lastKeyboardLiftTrace,
      );
    }
    final keyboardHeight = widget.keyboardInset.value;
    final keyboardVisualLift = (keyboardHeight - _bottomViewPadding).clamp(
      0.0,
      double.infinity,
    );
    if (keyboardVisualLift <= 0 || _cellHeight <= 0 || _viewportHeight <= 0) {
      return _KeyboardLiftTrace.zero(
        reason: keyboardVisualLift <= 0 ? 'keyboard-hidden' : 'not-laid-out',
        keyboardHeight: keyboardHeight,
        keyboardVisualLift: keyboardVisualLift,
        bottomViewPadding: _bottomViewPadding,
        cursorVisible: cursor?.visible ?? false,
        cursorInViewport: cursor?.inViewport ?? false,
        focused: _focusNode.hasFocus,
        active: widget.active,
        previous: _lastKeyboardLiftTrace,
      );
    }
    final hasCursorPosition = cursor != null && cursor.inViewport;
    final terminalKeyboardActive =
        _focusNode.hasFocus && (_textInputConnection?.attached ?? false);
    if (!hasCursorPosition && !terminalKeyboardActive) {
      return _KeyboardLiftTrace.zero(
        reason: cursor == null ? 'no-cursor' : 'no-cursor-position',
        keyboardHeight: keyboardHeight,
        keyboardVisualLift: keyboardVisualLift,
        bottomViewPadding: _bottomViewPadding,
        cursorVisible: cursor?.visible ?? false,
        cursorInViewport: cursor?.inViewport ?? false,
        focused: _focusNode.hasFocus,
        active: widget.active,
        previous: _lastKeyboardLiftTrace,
      );
    }
    final rowCount = _rows <= 0 ? 1 : _rows;
    final cursorX = hasCursorPosition ? cursor.x : -1;
    final cursorY = hasCursorPosition ? cursor.y : rowCount - 1;
    final cursorBottomY =
        widget.padding + ((cursorY + 1).clamp(1, rowCount) * _cellHeight);
    final cursorToBottomBarTop = (_viewportHeight - cursorBottomY).clamp(
      0.0,
      double.infinity,
    );
    final cursorMargin = _MotifTerminalViewState._keyboardCursorMargin;
    final lift = (keyboardVisualLift + cursorMargin - cursorToBottomBarTop)
        .clamp(0.0, keyboardVisualLift + cursorMargin);
    return _KeyboardLiftTrace(
      reason: hasCursorPosition
          ? (cursor.visible ? 'cursor' : 'cursor-hidden-positioned')
          : 'focused-bottom-row',
      lift: lift,
      keyboardHeight: keyboardHeight,
      keyboardVisualLift: keyboardVisualLift,
      bottomViewPadding: _bottomViewPadding,
      cursorToBottomBarTop: cursorToBottomBarTop,
      cursorBottomY: cursorBottomY,
      cursorX: cursorX,
      cursorY: cursorY,
      cursorVisible: cursor?.visible ?? false,
      cursorInViewport: cursor?.inViewport ?? false,
      viewportHeight: _viewportHeight,
      rows: _rows,
      cellHeight: _cellHeight,
      focused: _focusNode.hasFocus,
      active: widget.active,
    );
  }

  void _logKeyboardLift(_KeyboardLiftTrace trace, double previousLift) {
    final now = DateTime.now();
    final previousLogAt = _lastKeyboardLiftLogAt;
    _lastKeyboardLiftLogAt = now;
    final dtMs = previousLogAt == null
        ? null
        : now.difference(previousLogAt).inMilliseconds;
    Log.d(
      'pty=${widget.ptyId} '
      'reason=${trace.reason} '
      'lift=${trace.lift.toStringAsFixed(1)} '
      'prev=${previousLift.toStringAsFixed(1)} '
      'delta=${(trace.lift - previousLift).toStringAsFixed(1)} '
      'inset=${trace.keyboardHeight.toStringAsFixed(1)} '
      'visualInset=${trace.keyboardVisualLift.toStringAsFixed(1)} '
      'bottomPad=${trace.bottomViewPadding.toStringAsFixed(1)} '
      'cursorGap=${trace.cursorToBottomBarTop.toStringAsFixed(1)} '
      'cursorBottom=${trace.cursorBottomY.toStringAsFixed(1)} '
      'cursor=${trace.cursorX},${trace.cursorY} '
      'cursorVisible=${trace.cursorVisible} '
      'cursorInViewport=${trace.cursorInViewport} '
      'viewport=${trace.viewportHeight.toStringAsFixed(1)} '
      'rows=${trace.rows} '
      'cell=${trace.cellHeight.toStringAsFixed(1)} '
      'focused=${trace.focused} '
      'active=${trace.active} '
      'dt=${dtMs ?? '-'}ms',
      name: 'motif.terminal.lift',
    );
  }
}

class _CursorSnapshot {
  final bool visible;
  final bool inViewport;
  final int x;
  final int y;
  final int widthCells;
  final GhosttyRenderStateCursorVisualStyle style;

  const _CursorSnapshot({
    required this.visible,
    required this.inViewport,
    required this.x,
    required this.y,
    required this.widthCells,
    required this.style,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _CursorSnapshot &&
          other.visible == visible &&
          other.inViewport == inViewport &&
          other.x == x &&
          other.y == y &&
          other.widthCells == widthCells &&
          other.style == style;

  @override
  int get hashCode => Object.hash(visible, inViewport, x, y, widthCells, style);
}

class _KeyboardLiftTrace {
  final String reason;
  final double lift;
  final double keyboardHeight;
  final double keyboardVisualLift;
  final double bottomViewPadding;
  final double cursorToBottomBarTop;
  final double cursorBottomY;
  final int cursorX;
  final int cursorY;
  final bool cursorVisible;
  final bool cursorInViewport;
  final double viewportHeight;
  final int rows;
  final double cellHeight;
  final bool focused;
  final bool active;

  const _KeyboardLiftTrace({
    required this.reason,
    required this.lift,
    required this.keyboardHeight,
    required this.keyboardVisualLift,
    required this.bottomViewPadding,
    required this.cursorToBottomBarTop,
    required this.cursorBottomY,
    required this.cursorX,
    required this.cursorY,
    required this.cursorVisible,
    required this.cursorInViewport,
    required this.viewportHeight,
    required this.rows,
    required this.cellHeight,
    required this.focused,
    required this.active,
  });

  factory _KeyboardLiftTrace.zero({
    required String reason,
    required double keyboardHeight,
    required double keyboardVisualLift,
    required double bottomViewPadding,
    required bool cursorVisible,
    required bool cursorInViewport,
    required bool focused,
    required bool active,
    required _KeyboardLiftTrace? previous,
  }) {
    return _KeyboardLiftTrace(
      reason: reason,
      lift: 0,
      keyboardHeight: keyboardHeight,
      keyboardVisualLift: keyboardVisualLift,
      bottomViewPadding: bottomViewPadding,
      cursorToBottomBarTop: previous?.cursorToBottomBarTop ?? 0,
      cursorBottomY: previous?.cursorBottomY ?? 0,
      cursorX: previous?.cursorX ?? -1,
      cursorY: previous?.cursorY ?? -1,
      cursorVisible: cursorVisible,
      cursorInViewport: cursorInViewport,
      viewportHeight: previous?.viewportHeight ?? 0,
      rows: previous?.rows ?? 0,
      cellHeight: previous?.cellHeight ?? 0,
      focused: focused,
      active: active,
    );
  }
}
