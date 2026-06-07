part of '../motif_terminal_view.dart';

extension _MotifTerminalPointerInput on _MotifTerminalViewState {
  // ── pointer / scroll input (mirrors the demo TerminalView) ──
  GhosttyMouseButton _mapButton(int buttons) {
    if (buttons & 0x01 != 0) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT;
    }
    if (buttons & 0x02 != 0) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_RIGHT;
    }
    if (buttons & 0x04 != 0) {
      return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_MIDDLE;
    }
    return GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_UNKNOWN;
  }

  bool get _usesMobileDirectTouchScroll =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  bool _shouldScrollDirectTouch(PointerDeviceKind kind) {
    if (!_usesMobileDirectTouchScroll) {
      return false;
    }
    return kind == PointerDeviceKind.touch ||
        kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  void _onPointerDown(PointerDownEvent e) {
    if (!_initialized || _terminalError != null) return;
    _lastPointerPosition = e.localPosition;
    if (_touchScrollPointer == null && _shouldScrollDirectTouch(e.kind)) {
      _touchScrollPointer = e.pointer;
      _touchDownPosition = e.localPosition;
      _touchScrollDistance = 0;
      _stopScrollInertia(resetVelocity: true);
      _scrollAccumulator.reset();
      _lastScrollUpdateTime = null;
      return;
    }
    _worker?.encodeMouse(
      action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
      button: _mapButton(e.buttons),
      mods: 0,
      x: e.localPosition.dx,
      y: e.localPosition.dy,
    );
  }

  void _onPointerUp(PointerUpEvent e) {
    if (!_initialized || _terminalError != null) return;
    if (e.pointer == _touchScrollPointer) {
      _touchScrollPointer = null;
      // A touch that never really moved is a tap; deliver it as a click
      // so mouse-tracking apps (vim, htop, ...) still see touches.
      final downPosition = _touchDownPosition;
      _touchDownPosition = null;
      if (downPosition != null &&
          _touchScrollDistance < kTouchSlop &&
          (_snapshot?.mouseTrackingActive ?? false)) {
        _worker?.encodeMouse(
          action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
          button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
          mods: 0,
          x: downPosition.dx,
          y: downPosition.dy,
        );
        _worker?.encodeMouse(
          action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
          button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
          mods: 0,
          x: downPosition.dx,
          y: downPosition.dy,
        );
        return;
      }
      _startScrollInertia();
      return;
    }
    _worker?.encodeMouse(
      action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
      button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
      mods: 0,
      x: e.localPosition.dx,
      y: e.localPosition.dy,
    );
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (e.pointer != _touchScrollPointer) return;
    _touchScrollPointer = null;
    _touchDownPosition = null;
    _stopScrollInertia(resetVelocity: true);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_initialized || _terminalError != null) return;
    _lastPointerPosition = e.localPosition;
    if (e.pointer == _touchScrollPointer) {
      _touchScrollDistance += e.delta.distance;
      final pixels = touchMoveDeltaToScrollPixels(e.delta.dy);
      _scrollByPixels(pixels);
      _recordScrollVelocity(pixels, e.timeStamp);
      return;
    }
    _worker?.encodeMouse(
      action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
      button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_UNKNOWN,
      mods: 0,
      x: e.localPosition.dx,
      y: e.localPosition.dy,
    );
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (!_initialized || _terminalError != null) return;
    if (e is PointerScrollEvent) {
      _lastPointerPosition = e.localPosition;
      _stopScrollInertia(resetVelocity: true);
      _scrollByPixels(e.scrollDelta.dy);
      e.respond(allowPlatformDefault: false);
    } else if (e is PointerScrollInertiaCancelEvent) {
      _stopScrollInertia(resetVelocity: true);
    }
  }

  // Trackpad/touch two-finger scroll arrives as pan/zoom events.
  void _onPanZoomStart(PointerPanZoomStartEvent _) {
    _stopScrollInertia(resetVelocity: true);
    _scrollAccumulator.reset();
    _lastScrollUpdateTime = null;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (!_initialized || _terminalError != null) return;
    _lastPointerPosition = e.localPosition;
    final pixels = touchMoveDeltaToScrollPixels(e.panDelta.dy);
    _scrollByPixels(pixels);
    _recordScrollVelocity(pixels, e.timeStamp);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent _) {
    _startScrollInertia();
  }

  void _scrollByPixels(double pixels) {
    final rows = _scrollAccumulator.applyPixelDelta(pixels, _cellHeight);
    if (rows == 0) return;
    if (_snapshot?.mouseTrackingActive ?? false) {
      // The app (claude, vim with mouse, htop, ...) wants wheel events.
      _sendWheelEvents(rows);
    } else if (_snapshot?.alternateScreenActive ?? false) {
      // Alternate screen has no scrollback; emulate xterm's alternate
      // scroll mode by sending arrow keys (less, vim, man, ...).
      _sendAlternateScrollArrows(rows);
    } else {
      _worker?.scroll(rows);
    }
  }

  /// Wheel events are encoded as presses of buttons four/five (xterm
  /// codes 64/65); the protocol has no release for wheel buttons.
  void _sendWheelEvents(int rows) {
    final button = rows < 0
        ? GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FOUR
        : GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FIVE;
    final pos =
        _lastPointerPosition ??
        Offset(
          widget.padding + _cellWidth * _cols / 2,
          widget.padding + _cellHeight * _rows / 2,
        );
    for (var i = rows.abs(); i > 0; i--) {
      _worker?.encodeMouse(
        action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
        button: button,
        mods: 0,
        x: pos.dx,
        y: pos.dy,
      );
    }
  }

  void _sendAlternateScrollArrows(int rows) {
    final key = rows < 0
        ? GhosttyKey.GHOSTTY_KEY_ARROW_UP
        : GhosttyKey.GHOSTTY_KEY_ARROW_DOWN;
    for (var i = rows.abs(); i > 0; i--) {
      _worker?.encodeKey(
        key: key,
        action: GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
        mods: 0,
        text: null,
        unshiftedCodepoint: 0,
      );
    }
  }

  void _recordScrollVelocity(double pixels, Duration timeStamp) {
    final previous = _lastScrollUpdateTime;
    _lastScrollUpdateTime = timeStamp;
    if (previous == null) return;
    final dt =
        (timeStamp - previous).inMicroseconds / Duration.microsecondsPerSecond;
    if (dt <= 0 || dt > 0.2) {
      _scrollVelocity = 0;
      return;
    }
    final instantVelocity = pixels / dt;
    _scrollVelocity = _scrollVelocity == 0
        ? instantVelocity
        : _scrollVelocity * 0.35 + instantVelocity * 0.65;
  }

  void _startScrollInertia() {
    if (_cellHeight <= 0 || _scrollVelocity.abs() < 180) return;
    _scrollTicker ??= createTicker(_tickScrollInertia);
    _scrollSimulation = ClampingScrollSimulation(
      position: 0,
      velocity: _scrollVelocity.clamp(-8000, 8000).toDouble(),
    );
    _scrollSimulationStart = null;
    _scrollSimulationLastPosition = 0;
    _scrollTicker!
      ..stop()
      ..start();
  }

  void _tickScrollInertia(Duration elapsed) {
    final simulation = _scrollSimulation;
    if (simulation == null) return;
    _scrollSimulationStart ??= elapsed;
    final t =
        (elapsed - _scrollSimulationStart!).inMicroseconds /
        Duration.microsecondsPerSecond;
    final position = simulation.x(t);
    _scrollByPixels(position - _scrollSimulationLastPosition);
    _scrollSimulationLastPosition = position;
    if (simulation.isDone(t)) {
      _stopScrollInertia(resetVelocity: true);
    }
  }

  void _stopScrollInertia({required bool resetVelocity}) {
    _scrollTicker?.stop();
    _scrollSimulation = null;
    _scrollSimulationStart = null;
    _scrollSimulationLastPosition = 0;
    if (resetVelocity) {
      _scrollVelocity = 0;
      _lastScrollUpdateTime = null;
    }
  }

  /// Extract the visible grid as text (rows joined by newlines, trailing
  /// whitespace trimmed). Used by long-press → copy.
  String _visibleText() {
    return _snapshot?.visibleText ?? '';
  }

  Future<void> _copyVisible() async {
    if (!_initialized) return;
    await Clipboard.setData(ClipboardData(text: _visibleText()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Copied terminal output')));
    }
  }
}
