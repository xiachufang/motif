// ignore_for_file: invalid_use_of_protected_member

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

  bool get _usesTouchSelectionGestures =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  bool get _usesDesktopMouseSelection {
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };
  }

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
    _lastPointerKind = e.kind;
    _lastPointerPosition = e.localPosition;
    if (_isTerminalOverlayHotZone(e.localPosition)) {
      _terminalOverlayPointers.add(e.pointer);
      return;
    }
    _tapStartedWithSelection =
        (e.buttons & kPrimaryButton) != 0 && _selection != null;
    if (terminalContextMenuShouldOpen(buttons: e.buttons)) {
      _terminalContextMenuPointer = e.pointer;
      unawaited(_showDesktopTerminalContextMenu(e.position));
      return;
    }
    final terminalLink = _terminalLinkForDesktopActivation(e);
    if (terminalLink != null) {
      _suppressNextTerminalTap = true;
      _terminalHyperlinkPointers[e.pointer] = (
        match: terminalLink,
        downPosition: e.localPosition,
      );
      return;
    }
    if (_canStartMouseSelection(e)) {
      _beginMouseSelection(e);
      return;
    }
    if (_selection != null) {
      if (_shouldKeepTouchSelectionForTap(e)) {
        _touchSelectionPointer = e.pointer;
        _showTouchSelectionMenu();
        return;
      }
      _clearTerminalSelection();
    }
    if (_touchScrollPointer == null && _shouldScrollDirectTouch(e.kind)) {
      _touchScrollPointer = e.pointer;
      _touchDownPosition = e.localPosition;
      _touchDownSnapshot = _snapshot;
      _touchDownCell = _terminalCellAt(e.localPosition);
      _touchScrollDistance = 0;
      _scrollAccumulator.reset();
      return;
    }
    _flushRemoteBytesToWorker();
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
    if (_terminalOverlayPointers.remove(e.pointer)) return;
    final pressedLink = _terminalHyperlinkPointers.remove(e.pointer);
    if (pressedLink != null) {
      if ((e.localPosition - pressedLink.downPosition).distance < kTouchSlop) {
        unawaited(_activateTerminalLink(pressedLink.match));
      }
      return;
    }
    if (e.pointer == _terminalContextMenuPointer) {
      _terminalContextMenuPointer = null;
      return;
    }
    if (_isMouseSelectionPointer(e.pointer)) {
      _finishMouseSelection();
      return;
    }
    if (e.pointer == _touchSelectionPointer) {
      _touchSelectionPointer = null;
      return;
    }
    if (_touchSelectionGestureActive) return;
    if (e.pointer == _touchScrollPointer) {
      _touchScrollPointer = null;
      // A touch that never really moved is a tap; deliver it as a click
      // so mouse-tracking apps (vim, htop, ...) still see touches.
      final downPosition = _touchDownPosition;
      final downSnapshot = _touchDownSnapshot;
      final downCell = _touchDownCell;
      _touchDownPosition = null;
      _touchDownSnapshot = null;
      _touchDownCell = null;
      if (downPosition != null && _touchScrollDistance < kTouchSlop) {
        unawaited(
          _openLinkOrSendTouchClick(
            downPosition,
            snapshot: downSnapshot,
            point: downCell,
            startedWithSelection: _tapStartedWithSelection,
          ),
        );
        return;
      }
      return;
    }
    _flushRemoteBytesToWorker();
    _worker?.encodeMouse(
      action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
      button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
      mods: 0,
      x: e.localPosition.dx,
      y: e.localPosition.dy,
    );
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (_terminalOverlayPointers.remove(e.pointer)) return;
    if (_terminalHyperlinkPointers.remove(e.pointer) != null) return;
    if (e.pointer == _terminalContextMenuPointer) {
      _terminalContextMenuPointer = null;
      return;
    }
    if (_isMouseSelectionPointer(e.pointer)) {
      _finishMouseSelection();
      return;
    }
    if (e.pointer == _touchSelectionPointer) {
      _touchSelectionPointer = null;
      _onTerminalLongPressCancel();
      return;
    }
    if (e.pointer != _touchScrollPointer) return;
    _touchScrollPointer = null;
    _touchDownPosition = null;
    _touchDownSnapshot = null;
    _touchDownCell = null;
    _stopScrollInertia();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_initialized || _terminalError != null) return;
    _lastPointerPosition = e.localPosition;
    if (_terminalOverlayPointers.contains(e.pointer)) return;
    if (_terminalHyperlinkPointers.containsKey(e.pointer)) return;
    if (e.pointer == _terminalContextMenuPointer) return;
    if (_isMouseSelectionMove(e)) {
      _updateMouseSelection(e.localPosition);
      return;
    }
    if (e.pointer == _touchSelectionPointer) return;
    if (_touchSelectionGestureActive) return;
    if (e.pointer == _touchScrollPointer) {
      _touchScrollDistance += e.delta.distance;
      return;
    }
    _flushRemoteBytesToWorker();
    _worker?.encodeMouse(
      action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
      button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_UNKNOWN,
      mods: 0,
      x: e.localPosition.dx,
      y: e.localPosition.dy,
    );
  }

  void _onPointerSignal(PointerSignalEvent e) {
    _logScrollDiagnostic(
      'pointer-signal',
      detail: switch (e) {
        PointerScrollEvent() =>
          'type=scroll kind=${e.kind.name} '
              'delta=${e.scrollDelta.dx.toStringAsFixed(2)},'
              '${e.scrollDelta.dy.toStringAsFixed(2)}',
        PointerScrollInertiaCancelEvent() => 'type=inertia-cancel',
        _ => 'type=${e.runtimeType}',
      },
      force: _scrollDiagnosticSequence < 12,
    );
    if (!_initialized || _terminalError != null) {
      _logScrollDiagnostic('pointer-signal-ignored', force: true);
      return;
    }
    if (e is PointerScrollEvent) {
      _lastPointerPosition = e.localPosition;
      final snapshot = _snapshot;
      final canHandle =
          (snapshot?.mouseTrackingActive ?? false) ||
          (snapshot?.alternateScreenActive ?? false);
      if (canHandle && e.scrollDelta.dy != 0) {
        // The terminal consumes wheel input only when the application owns it.
        GestureBinding.instance.pointerSignalResolver.register(
          e,
          _handleTerminalPointerScroll,
        );
        _logScrollDiagnostic(
          'pointer-signal-registered',
          detail: 'owner=terminal-app',
        );
      } else if (_terminalHistoryScrollEnabled && e.scrollDelta.dy != 0) {
        // Keep ordinary history in Flutter's ScrollPosition. This custom
        // pointer entry only removes Flutter's wheel boundary clamp so the
        // platform bouncing physics also works with precise pointer devices.
        GestureBinding.instance.pointerSignalResolver.register(
          e,
          _handleTerminalHistoryPointerScroll,
        );
        _logScrollDiagnostic(
          'pointer-signal-registered',
          detail: 'owner=flutter-scroll-position',
        );
      } else {
        _logScrollDiagnostic(
          'pointer-signal-fallthrough',
          detail: 'owner=flutter-scrollable canHandle=$canHandle',
        );
      }
    } else if (e is PointerScrollInertiaCancelEvent) {
      // The surrounding Scrollable receives the same signal and calls
      // position.pointerScroll(0), which starts the platform spring. Starting
      // it here as well resets the simulation and looks like a second bounce.
      _scrollAccumulator.reset();
    }
  }

  void _handleTerminalHistoryPointerScroll(PointerSignalEvent signal) {
    final event = signal as PointerScrollEvent;
    if (_terminalScrollController.hasClients && event.scrollDelta.dy != 0) {
      _terminalScrollController.position.pointerScroll(event.scrollDelta.dy);
      event.respond(allowPlatformDefault: false);
    }
  }

  void _handleTerminalPointerScroll(PointerSignalEvent signal) {
    final event = signal as PointerScrollEvent;
    final rows = event.kind == PointerDeviceKind.mouse
        ? terminalRowsFromDiscreteWheel(event.scrollDelta.dy)
        : _scrollAccumulator.applyPixelDelta(event.scrollDelta.dy, _cellHeight);
    if (rows != 0) _sendTerminalAppScrollRows(rows);
    _logScrollDiagnostic(
      'pointer-signal-resolved',
      detail: 'owner=terminal-app rows=$rows kind=${event.kind.name}',
    );
    event.respond(allowPlatformDefault: false);
  }

  bool get _canSelectTerminalText => !(_snapshot?.mouseTrackingActive ?? false);

  MouseCursor get _terminalMouseCursor =>
      _terminalLinkMode && _hoveredTerminalLink != null
      ? SystemMouseCursors.click
      : SystemMouseCursors.text;

  void _onPointerHover(PointerHoverEvent e) {
    _lastPointerPosition = e.localPosition;
    final keyboard = HardwareKeyboard.instance;
    _setTerminalLinkMode(
      terminalLinkModifierPressed(
        control: keyboard.isControlPressed,
        meta: keyboard.isMetaPressed,
      ),
    );
    _updateHoveredTerminalLink();
  }

  void _onPointerExit(PointerExitEvent _) {
    final hadHover = _hoveredTerminalLink != null;
    _lastPointerPosition = null;
    _hoveredTerminalLink = null;
    _terminalLinkHoverCell = null;
    _terminalLinkHoverFrameId = null;
    if (hadHover && mounted) setState(() {});
  }

  void _setTerminalLinkMode(bool enabled) {
    if (_terminalLinkMode == enabled) return;
    _terminalLinkMode = enabled;
    _terminalLinkHoverCell = null;
    _terminalLinkHoverFrameId = null;
    if (enabled) {
      _updateHoveredTerminalLink(notify: false);
    } else {
      _hoveredTerminalLink = null;
    }
    if (mounted) setState(() {});
  }

  void _refreshTerminalLinkForSnapshot() {
    if (!_terminalLinkMode) return;
    _terminalLinkHoverCell = null;
    _terminalLinkHoverFrameId = null;
    _updateHoveredTerminalLink(notify: false);
  }

  void _updateHoveredTerminalLink({bool notify = true}) {
    final snapshot = _snapshot;
    final localPosition = _lastPointerPosition;
    if (!_terminalLinkMode || snapshot == null || localPosition == null) {
      final changed = _hoveredTerminalLink != null;
      _hoveredTerminalLink = null;
      _terminalLinkHoverCell = null;
      _terminalLinkHoverFrameId = null;
      if (changed && notify && mounted) setState(() {});
      return;
    }
    final cell = _terminalCellAt(localPosition);
    if (_terminalLinkHoverFrameId == snapshot.frameId &&
        _terminalLinkHoverCell == cell) {
      return;
    }
    _terminalLinkHoverFrameId = snapshot.frameId;
    _terminalLinkHoverCell = cell;
    final next = TerminalLinkMatcher.matchAt(snapshot, cell);
    final changed = !_sameTerminalLink(next, _hoveredTerminalLink);
    _hoveredTerminalLink = next;
    if (changed && notify && mounted) setState(() {});
  }

  TerminalLinkMatch? _linkAtLocalPosition(Offset? localPosition) {
    final snapshot = _snapshot;
    if (snapshot == null || localPosition == null) return null;
    return TerminalLinkMatcher.matchAt(
      snapshot,
      _terminalCellAt(localPosition),
    );
  }

  bool _sameTerminalLink(TerminalLinkMatch? a, TerminalLinkMatch? b) {
    if (a == null || b == null) return a == b;
    if (a.snapshotId != b.snapshotId ||
        a.kind != b.kind ||
        a.target != b.target ||
        a.segments.length != b.segments.length) {
      return false;
    }
    for (var i = 0; i < a.segments.length; i++) {
      final aa = a.segments[i];
      final bb = b.segments[i];
      if (aa.row != bb.row ||
          aa.startCol != bb.startCol ||
          aa.endCol != bb.endCol) {
        return false;
      }
    }
    return true;
  }

  TerminalLinkMatch? _terminalLinkForDesktopActivation(PointerDownEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (!terminalHyperlinkShouldActivate(
      buttons: event.buttons,
      control: keyboard.isControlPressed,
      meta: keyboard.isMetaPressed,
    )) {
      return null;
    }
    if (!_terminalLinkMode) _setTerminalLinkMode(true);
    return _linkAtLocalPosition(event.localPosition);
  }

  Future<void> _activateTerminalLink(TerminalLinkMatch match) async {
    TerminalFileTarget? file = match.file;
    if (file == null && match.target.toLowerCase().startsWith('file:')) {
      try {
        file = TerminalFileTarget.fromFileUri(match.target);
      } catch (_) {
        file = null;
      }
    }
    file ??= match.kind == TerminalLinkKind.osc8
        ? TerminalFileTarget.tryParse(match.target)
        : null;
    if (file != null) {
      final openFile = widget.onOpenFile;
      if (openFile == null) {
        if (mounted) showMotifToast(context, 'File preview is unavailable.');
        return;
      }
      try {
        await openFile(file);
      } catch (error) {
        if (mounted) showMotifToast(context, 'Could not open ${file.path}.');
      }
      return;
    }

    final opened = await openTerminalHyperlink(match.target);
    if (!opened && mounted) {
      showMotifToast(context, 'Could not open this terminal link.');
    }
  }

  Future<void> _openLinkOrSendTouchClick(
    Offset localPosition, {
    required TerminalSnapshot? snapshot,
    required TerminalCellPoint? point,
    required bool startedWithSelection,
  }) async {
    if (startedWithSelection) return;
    final link = snapshot == null || point == null
        ? null
        : TerminalLinkMatcher.matchAt(snapshot, point);
    if (link != null) {
      _suppressNextTerminalTap = true;
      await _activateTerminalLink(link);
      return;
    }
    if (!mounted || !(_snapshot?.mouseTrackingActive ?? false)) return;
    _sendTouchClick(localPosition);
  }

  void _sendTouchClick(Offset localPosition) {
    _flushRemoteBytesToWorker();
    _worker?.encodeMouse(
      action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
      button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
      mods: 0,
      x: localPosition.dx,
      y: localPosition.dy,
    );
    _worker?.encodeMouse(
      action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE,
      button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
      mods: 0,
      x: localPosition.dx,
      y: localPosition.dy,
    );
  }

  bool _canStartMouseSelection(PointerDownEvent e) {
    if (!_canSelectTerminalText) return false;
    if (!_usesDesktopMouseSelection) return false;
    if (e.kind != PointerDeviceKind.mouse) return false;
    return (e.buttons & 0x01) != 0;
  }

  bool _isMouseSelectionMove(PointerMoveEvent e) {
    if (_mouseSelectionAnchor == null) return false;
    if (_mouseSelectionPointer == null) return false;
    if ((e.buttons & 0x01) == 0) return false;
    return e.pointer == _mouseSelectionPointer;
  }

  bool _isMouseSelectionPointer(int pointer) {
    if (_mouseSelectionAnchor == null) return false;
    return pointer == _mouseSelectionPointer;
  }

  bool _isTouchSelectionKind(PointerDeviceKind? kind) {
    if (kind == null) return true;
    return kind == PointerDeviceKind.touch ||
        kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  bool _shouldKeepTouchSelectionForTap(PointerDownEvent e) {
    if (!_usesTouchSelectionGestures || !_touchSelectionActive) return false;
    if (!_isTouchSelectionKind(e.kind)) return false;
    final snapshot = _snapshot;
    final selection = _selection;
    if (snapshot == null || selection == null) return false;
    final cell = _terminalCellAt(e.localPosition);
    return selection.intersectsCell(
      row: cell.row,
      col: cell.col,
      widthCells: 1,
      cols: snapshot.cols,
    );
  }

  Future<void> _showDesktopTerminalContextMenu(Offset globalPosition) async {
    if (!mounted) return;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (overlay == null || !overlay.hasSize) return;
    final localPosition = overlay.globalToLocal(globalPosition);
    final x = localPosition.dx.clamp(0.0, overlay.size.width).toDouble();
    final y = localPosition.dy.clamp(0.0, overlay.size.height).toDouble();
    final action = await showMenu<_TerminalContextMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        x,
        y,
        overlay.size.width - x,
        overlay.size.height - y,
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: MotifSpacing.xs),
      constraints: const BoxConstraints(minWidth: 112, maxWidth: 160),
      items: [
        _terminalContextMenuItem(
          action: _TerminalContextMenuAction.copy,
          enabled: _selection != null,
          icon: Icons.copy_outlined,
          label: 'Copy',
        ),
        _terminalContextMenuItem(
          action: _TerminalContextMenuAction.paste,
          enabled: widget.motif.canInput,
          icon: Icons.content_paste,
          label: 'Paste',
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _TerminalContextMenuAction.copy:
        await _copySelectedText();
      case _TerminalContextMenuAction.paste:
        await _pasteFromClipboard();
    }
  }

  PopupMenuItem<_TerminalContextMenuAction> _terminalContextMenuItem({
    required _TerminalContextMenuAction action,
    required bool enabled,
    required IconData icon,
    required String label,
  }) {
    return PopupMenuItem<_TerminalContextMenuAction>(
      value: action,
      enabled: enabled,
      height: MotifControlSize.sm,
      padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.md),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: MotifIconSize.sm),
          const SizedBox(width: MotifSpacing.sm),
          Text(label, style: MotifType.subhead),
        ],
      ),
    );
  }

  void _beginMouseSelection(PointerDownEvent e) {
    if (terminalTapRequestsFocus(selectionActive: _selection != null)) {
      _requestFocusWithoutKeyboard();
    }
    _stopScrollInertia();
    _clearTerminalSelection();
    _mouseSelectionPointer = e.pointer;
    final anchor = _terminalCellAt(e.localPosition);
    _mouseSelectionAnchor = anchor;
    _mouseSelectionDownPosition = e.localPosition;
    _mouseSelectionStarted = false;
  }

  void _updateMouseSelection(Offset localPosition) {
    final anchor = _mouseSelectionAnchor;
    if (anchor == null) return;
    if (!_mouseSelectionStarted) {
      final downPosition = _mouseSelectionDownPosition;
      if (downPosition == null ||
          (localPosition - downPosition).distance < kTouchSlop) {
        return;
      }
      _mouseSelectionStarted = true;
      _worker?.beginSelection(anchor);
    }
    _updateTerminalSelection(anchor, localPosition);
  }

  void _finishMouseSelection() {
    _mouseSelectionPointer = null;
    _mouseSelectionAnchor = null;
    _mouseSelectionDownPosition = null;
    _mouseSelectionStarted = false;
  }

  void _onTerminalLongPressStart(LongPressStartDetails details) {
    if (!_initialized || _terminalError != null) return;
    if (!_usesTouchSelectionGestures) return;
    if (!_isTouchSelectionKind(_lastPointerKind)) return;
    if (!_canSelectTerminalText) return;
    final wordSelection = _snapshot?.wordSelectionAt(
      _terminalCellAt(details.localPosition),
    );
    if (wordSelection == null) return;
    _requestFocusWithoutKeyboard();
    _stopScrollInertia();
    final selectionPointer = _touchScrollPointer;
    _touchScrollPointer = null;
    _touchDownPosition = null;
    _touchDownSnapshot = null;
    _touchDownCell = null;
    _clearTerminalSelection();
    _touchSelectionPointer = selectionPointer;
    _touchSelectionGestureActive = true;
    _touchSelectionActive = true;
    _selectionGestureFeedback();
    _worker?.selectWord(_terminalCellAt(details.localPosition));
  }

  void _onTerminalLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_touchSelectionGestureActive) return;
    _hideTouchSelectionMenu();
    _worker?.updateSelectionEnd(_terminalCellAt(details.localPosition));
  }

  void _onTerminalLongPressEnd(LongPressEndDetails _) {
    if (!_touchSelectionGestureActive) return;
    _touchSelectionGestureActive = false;
    _showTouchSelectionHandles();
    _showTouchSelectionMenu();
  }

  void _onTerminalLongPressCancel() {
    if (!_touchSelectionGestureActive) return;
    _clearTerminalSelection();
  }

  int _terminalColumnAt(Offset localPosition) {
    final snapshot = _snapshot;
    final cols = snapshot?.cols ?? _cols;
    final safeCols = cols <= 0 ? 1 : cols;
    final col = _cellWidth <= 0
        ? 0
        : ((localPosition.dx - widget.padding) / _cellWidth).floor();
    return _clampTerminalInt(col, 0, safeCols - 1);
  }

  TerminalCellPoint _terminalCellAt(Offset localPosition) {
    final snapshot = _snapshot;
    final localRow = _cellHeight <= 0
        ? 0.0
        : (localPosition.dy - widget.padding) / _cellHeight;
    final screenRow = (_visualViewportOffset + localRow).floor();
    final maxScreenRow = snapshot == null
        ? _rows - 1
        : snapshot.scrollTotalRows - 1;
    return TerminalCellPoint(
      row: _clampTerminalInt(screenRow, 0, maxScreenRow),
      col: _terminalColumnAt(localPosition),
    );
  }

  void _updateTerminalSelection(TerminalCellPoint _, Offset localPosition) {
    _worker?.updateSelectionEnd(_terminalCellAt(localPosition));
  }

  void _clearTerminalSelection() {
    final hadSelection = _selection != null;
    _worker?.clearSelection();
    _discardTerminalSelectionState();
    if (!hadSelection) return;
    if (mounted) setState(() {});
  }

  void _discardTerminalSelectionState() {
    _hideTouchSelectionMenu();
    _hideTouchSelectionHandles();
    _mouseSelectionAnchor = null;
    _mouseSelectionPointer = null;
    _mouseSelectionDownPosition = null;
    _mouseSelectionStarted = false;
    _touchSelectionActive = false;
    _touchSelectionGestureActive = false;
    _touchSelectionPointer = null;
    _touchSelectionDragHandle = null;
    _selection = null;
  }

  TextSelectionControls get _touchSelectionControls {
    return defaultTargetPlatform == TargetPlatform.iOS
        ? cupertino.cupertinoTextSelectionHandleControls
        : materialTextSelectionHandleControls;
  }

  bool get _canShowTouchSelectionOverlays {
    return mounted &&
        _usesTouchSelectionGestures &&
        _touchSelectionActive &&
        _selection != null;
  }

  void _showTouchSelectionHandles() {
    if (!_canShowTouchSelectionOverlays) {
      _hideTouchSelectionHandles();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final entry = _touchSelectionHandlesEntry;
    if (entry != null) {
      entry.markNeedsBuild();
      return;
    }
    final newEntry = OverlayEntry(builder: _buildTouchSelectionHandlesOverlay);
    _touchSelectionHandlesEntry = newEntry;
    overlay.insert(newEntry);
  }

  void _hideTouchSelectionHandles() {
    _touchSelectionHandlesEntry?.remove();
    _touchSelectionHandlesEntry = null;
  }

  Widget _buildTouchSelectionHandlesOverlay(BuildContext overlayContext) {
    if (!_canShowTouchSelectionOverlays) return const SizedBox.shrink();
    final endpoints = _touchSelectionOverlayEndpoints();
    if (endpoints == null) return const SizedBox.shrink();
    final controls = _touchSelectionControls;
    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _buildTouchSelectionHandle(
            overlayContext: overlayContext,
            handle: _TouchSelectionHandle.start,
            endpoint: endpoints.start,
            controls: controls,
          ),
          _buildTouchSelectionHandle(
            overlayContext: overlayContext,
            handle: _TouchSelectionHandle.end,
            endpoint: endpoints.end,
            controls: controls,
          ),
        ],
      ),
    );
  }

  Widget _buildTouchSelectionHandle({
    required BuildContext overlayContext,
    required _TouchSelectionHandle handle,
    required Offset endpoint,
    required TextSelectionControls controls,
  }) {
    final type = switch (handle) {
      _TouchSelectionHandle.start => TextSelectionHandleType.left,
      _TouchSelectionHandle.end => TextSelectionHandleType.right,
    };
    final anchor = controls.getHandleAnchor(type, _cellHeight);
    return Positioned(
      left: endpoint.dx - anchor.dx,
      top: endpoint.dy - anchor.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (details) =>
            _onTouchSelectionHandleDragStart(handle, details),
        onPanUpdate: _onTouchSelectionHandleDragUpdate,
        onPanEnd: (_) => _onTouchSelectionHandleDragEnd(),
        onPanCancel: _onTouchSelectionHandleDragEnd,
        child: controls.buildHandle(overlayContext, type, _cellHeight),
      ),
    );
  }

  ({Offset start, Offset end})? _touchSelectionOverlayEndpoints() {
    final global = _touchSelectionGlobalEndpoints();
    if (global == null) return null;
    final overlayBox =
        Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) return null;
    return (
      start: overlayBox.globalToLocal(global.start),
      end: overlayBox.globalToLocal(global.end),
    );
  }

  ({Offset start, Offset end})? _touchSelectionGlobalEndpoints() {
    final snapshot = _snapshot;
    final rawSelection = _selection;
    final terminalBox =
        _terminalSurfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (snapshot == null ||
        rawSelection == null ||
        terminalBox == null ||
        !terminalBox.hasSize ||
        _cellWidth <= 0 ||
        _cellHeight <= 0) {
      return null;
    }
    final selection = snapshot.alignSelectionToCellBoundaries(rawSelection);
    if (_screenRowInVisualViewport(selection.base.row) == null ||
        _screenRowInVisualViewport(selection.extent.row) == null) {
      return null;
    }
    return (
      start: terminalBox.localToGlobal(_selectionStartEndpoint(selection.base)),
      end: terminalBox.localToGlobal(_selectionEndEndpoint(selection.extent)),
    );
  }

  Offset _selectionStartEndpoint(TerminalCellPoint point) {
    final viewportRow = _screenRowInVisualViewport(point.row) ?? point.row;
    return Offset(
      widget.padding + point.col * _cellWidth,
      widget.padding + (viewportRow + 1) * _cellHeight,
    );
  }

  Offset _selectionEndEndpoint(TerminalCellPoint point) {
    final viewportRow = _screenRowInVisualViewport(point.row) ?? point.row;
    return Offset(
      widget.padding + (point.col + 1) * _cellWidth,
      widget.padding + (viewportRow + 1) * _cellHeight,
    );
  }

  void _onTouchSelectionHandleDragStart(
    _TouchSelectionHandle handle,
    DragStartDetails _,
  ) {
    _touchSelectionDragHandle = handle;
    _selectionGestureFeedback();
    _hideTouchSelectionMenu();
  }

  void _selectionGestureFeedback() {
    unawaited(HapticFeedback.selectionClick());
  }

  void _onTouchSelectionHandleDragUpdate(DragUpdateDetails details) {
    final activeHandle = _touchSelectionDragHandle;
    final current = _selection?.normalized;
    final terminalBox =
        _terminalSurfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (activeHandle == null || current == null || terminalBox == null) {
      return;
    }
    final localPosition = terminalBox.globalToLocal(details.globalPosition);
    final point = _terminalCellAt(localPosition);
    final next = switch (activeHandle) {
      _TouchSelectionHandle.start => _selectionAdjustedFromStart(
        current,
        point,
      ),
      _TouchSelectionHandle.end => _selectionAdjustedFromEnd(current, point),
    };
    _worker?.setSelection(
      baseScreenPoint: next.selection.base,
      extentScreenPoint: next.selection.extent,
    );
    _touchSelectionDragHandle = next.activeHandle;
    _touchSelectionHandlesEntry?.markNeedsBuild();
  }

  ({TerminalSelection selection, _TouchSelectionHandle activeHandle})
  _selectionAdjustedFromStart(
    TerminalSelection current,
    TerminalCellPoint point,
  ) {
    if (point.compareTo(current.extent) <= 0) {
      return (
        selection: TerminalSelection(base: point, extent: current.extent),
        activeHandle: _TouchSelectionHandle.start,
      );
    }
    return (
      selection: TerminalSelection(base: current.extent, extent: point),
      activeHandle: _TouchSelectionHandle.end,
    );
  }

  ({TerminalSelection selection, _TouchSelectionHandle activeHandle})
  _selectionAdjustedFromEnd(
    TerminalSelection current,
    TerminalCellPoint point,
  ) {
    if (point.compareTo(current.base) >= 0) {
      return (
        selection: TerminalSelection(base: current.base, extent: point),
        activeHandle: _TouchSelectionHandle.end,
      );
    }
    return (
      selection: TerminalSelection(base: point, extent: current.base),
      activeHandle: _TouchSelectionHandle.start,
    );
  }

  void _onTouchSelectionHandleDragEnd() {
    if (_touchSelectionDragHandle == null) return;
    _touchSelectionDragHandle = null;
    _showTouchSelectionHandles();
    _showTouchSelectionMenu();
  }

  void _showTouchSelectionMenu() {
    if (!_canShowTouchSelectionOverlays) {
      _hideTouchSelectionMenu();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _hideTouchSelectionMenu();
    final entry = OverlayEntry(builder: _buildTouchSelectionMenuOverlay);
    _touchSelectionMenuEntry = entry;
    overlay.insert(entry);
  }

  void _hideTouchSelectionMenu() {
    _touchSelectionMenuEntry?.remove();
    _touchSelectionMenuEntry = null;
  }

  Widget _buildTouchSelectionMenuOverlay(BuildContext overlayContext) {
    final anchors = _touchSelectionToolbarAnchors();
    if (!_canShowTouchSelectionOverlays || anchors == null) {
      return const SizedBox.shrink();
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            _hideTouchSelectionMenu();
            unawaited(_copySelectedText());
          },
        ),
      ],
    );
  }

  TextSelectionToolbarAnchors? _touchSelectionToolbarAnchors() {
    final snapshot = _snapshot;
    final selection = _selection?.normalized;
    final terminalBox =
        _terminalSurfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (snapshot == null ||
        selection == null ||
        terminalBox == null ||
        !terminalBox.hasSize ||
        _cellWidth <= 0 ||
        _cellHeight <= 0) {
      return null;
    }
    final visible = snapshot.visibleSelection(selection);
    if (visible == null) return null;
    final baseRow = visible.base.row - _visualViewportOffset;
    final extentRow = visible.extent.row - _visualViewportOffset;
    final sameRow = visible.base.row == visible.extent.row;
    final left = sameRow
        ? widget.padding + visible.base.col * _cellWidth
        : widget.padding;
    final right = sameRow
        ? widget.padding + (visible.extent.col + 1) * _cellWidth
        : widget.padding + _cols * _cellWidth;
    final top = widget.padding + baseRow * _cellHeight;
    final bottom = widget.padding + (extentRow + 1) * _cellHeight;
    final centerX = left + (right - left) / 2;
    return TextSelectionToolbarAnchors(
      primaryAnchor: terminalBox.localToGlobal(Offset(centerX, top)),
      secondaryAnchor: terminalBox.localToGlobal(Offset(centerX, bottom)),
    );
  }

  double? _screenRowInVisualViewport(int screenRow) {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    final row = screenRow - _visualViewportOffset;
    if (row <= -1 || row >= snapshot.rows) return null;
    return row;
  }

  int _clampTerminalInt(int value, int min, int max) {
    if (max < min) return min;
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  // Trackpad/touch two-finger scroll arrives as pan/zoom events.
  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    final snapshot = _snapshot;
    final terminalAppOwnsGesture =
        (snapshot?.mouseTrackingActive ?? false) ||
        (snapshot?.alternateScreenActive ?? false);
    _logScrollDiagnostic(
      'panzoom-start',
      detail:
          'kind=${event.kind.name} owner='
          '${terminalAppOwnsGesture
              ? 'terminal-app'
              : _terminalHistoryScrollEnabled
              ? 'flutter-scrollable'
              : 'none'}',
      force: true,
    );
    if (terminalAppOwnsGesture) _scrollAccumulator.reset();
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (!_initialized || _terminalError != null) {
      _logScrollDiagnostic('panzoom-update-ignored', force: true);
      return;
    }
    _lastPointerPosition = e.localPosition;
    final snapshot = _snapshot;
    final terminalAppOwnsGesture =
        (snapshot?.mouseTrackingActive ?? false) ||
        (snapshot?.alternateScreenActive ?? false);
    _logScrollDiagnostic(
      'panzoom-update',
      detail:
          'kind=${e.kind.name} '
          'delta=${e.panDelta.dx.toStringAsFixed(2)},'
          '${e.panDelta.dy.toStringAsFixed(2)} '
          'owner=${terminalAppOwnsGesture
              ? 'terminal-app'
              : _terminalHistoryScrollEnabled
              ? 'flutter-scrollable'
              : 'none'}',
    );
    if (terminalAppOwnsGesture) {
      final rows = _scrollAccumulator.applyPixelDelta(
        touchMoveDeltaToScrollPixels(e.localPanDelta.dy),
        _cellHeight,
      );
      if (rows != 0) _sendTerminalAppScrollRows(rows);
    }
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    _logScrollDiagnostic(
      'panzoom-end',
      detail: 'kind=${event.kind.name}',
      force: true,
    );
  }

  bool get _terminalHistoryScrollEnabled {
    final snapshot = _snapshot;
    return snapshot != null &&
        snapshot.hasScrollback &&
        !snapshot.mouseTrackingActive &&
        !snapshot.alternateScreenActive;
  }

  double get _terminalScrollMaxExtent {
    final snapshot = _snapshot;
    if (snapshot == null ||
        snapshot.mouseTrackingActive ||
        snapshot.alternateScreenActive ||
        !snapshot.hasScrollback ||
        _cellHeight <= 0) {
      return 0;
    }
    return snapshot.maxViewportOffset * _cellHeight;
  }

  void _onTerminalScrollPositionChanged() {
    _logScrollDiagnostic('scroll-position-listener');
    if (!_terminalScrollController.hasClients || _cellHeight <= 0) {
      return;
    }
    final snapshot = _snapshot;
    if (snapshot == null ||
        snapshot.mouseTrackingActive ||
        snapshot.alternateScreenActive ||
        !snapshot.hasScrollback ||
        !_terminalScrollController.position.hasContentDimensions) {
      return;
    }

    final position = _terminalScrollController.position;
    final laidOutMaxOffset = (position.maxScrollExtent / _cellHeight).round();
    final projection = TerminalViewportProjection.calculate(
      scrollPixels: position.pixels,
      rowHeight: _cellHeight,
      maxViewportOffset: laidOutMaxOffset,
      maxScrollPixels: position.maxScrollExtent,
      snapshotViewportOffset: snapshot.viewportOffset,
      snapshotIsLive: snapshot.viewportActive,
      followsLatest: _terminalScrollController.followsLatest,
    );
    _logScrollDiagnostic(
      'scroll-position-mapped',
      detail:
          'target=${projection.target} '
          'remainder=${projection.pixelRemainder.toStringAsFixed(2)} '
          'laidOutMax=$laidOutMaxOffset',
    );
    if (mounted) setState(() {});
    _touchSelectionHandlesEntry?.markNeedsBuild();
    _touchSelectionMenuEntry?.markNeedsBuild();
    _requestTerminalViewport(projection.target);
  }

  void _requestTerminalViewport(TerminalViewportTarget target) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      _logScrollDiagnostic(
        'viewport-request-ignored',
        detail: 'reason=no-snapshot target=$target',
        force: true,
      );
      return;
    }
    final clamped = target.offset.clamp(0, snapshot.maxViewportOffset);
    if (target.latest) {
      if (snapshot.viewportActive && _pendingViewportRequest == null) {
        _logScrollDiagnostic(
          'viewport-request-noop',
          detail: 'reason=already-live target=$target clamped=$clamped',
        );
        return;
      }
      if (_pendingViewportRequest?.latest == true) {
        _logScrollDiagnostic(
          'viewport-request-noop',
          detail: 'reason=waiting-live target=$target clamped=$clamped',
        );
        return;
      }
      _pendingViewportRequest = (offset: clamped, latest: true);
      _scrollbarVisibility.showTemporarily();
      _logScrollDiagnostic(
        'viewport-request-send',
        detail: 'command=bottom target=$target clamped=$clamped',
        force: true,
      );
      _worker?.scrollToBottom();
      return;
    }
    if (clamped == snapshot.viewportOffset &&
        !snapshot.viewportActive &&
        _pendingViewportRequest == null) {
      _logScrollDiagnostic(
        'viewport-request-noop',
        detail: 'reason=same-offset target=$target clamped=$clamped',
      );
      return;
    }
    final pendingRequest = _pendingViewportRequest;
    if (pendingRequest != null &&
        !pendingRequest.latest &&
        pendingRequest.offset == clamped) {
      _logScrollDiagnostic(
        'viewport-request-noop',
        detail: 'reason=already-requested target=$target clamped=$clamped',
      );
      return;
    }
    _pendingViewportRequest = (offset: clamped, latest: false);
    _scrollbarVisibility.showTemporarily();
    _logScrollDiagnostic(
      'viewport-request-send',
      detail: 'command=row target=$target clamped=$clamped',
      force: true,
    );
    _worker?.scrollToOffset(clamped);
  }

  void _scheduleTerminalScrollPositionRestore(double viewportOffset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_terminalScrollController.hasClients ||
          _cellHeight <= 0) {
        return;
      }
      final position = _terminalScrollController.position;
      if (!position.hasContentDimensions) return;
      final target = (viewportOffset * _cellHeight)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((position.pixels - target).abs() <= 0.01) return;
      _terminalScrollController.jumpTo(target);
    });
  }

  void _sendTerminalAppScrollRows(int rows) {
    final snapshot = _snapshot;
    if (snapshot == null || rows == 0) return;
    if (snapshot.mouseTrackingActive) {
      _sendWheelEvents(rows);
    } else if (snapshot.alternateScreenActive) {
      _sendAlternateScrollArrows(rows);
    }
  }

  bool _isReturnToCursorHotZone(Offset position) {
    final snapshot = _snapshot;
    if (snapshot == null ||
        !terminalReturnToCursorShouldBeVisible(
          controlsVisible: _scrollbarVisibility.visible,
          hasScrollback: snapshot.hasScrollback,
          alternateScreenActive: snapshot.alternateScreenActive,
          isAtLatest: snapshot.isAtLatest,
        ) ||
        _viewportWidth <= 0 ||
        _viewportHeight <= 0) {
      return false;
    }
    return TerminalReturnToCursorButton.hitRectForViewport(
      Size(_viewportWidth, _viewportHeight),
    ).contains(position);
  }

  bool _isTerminalOverlayHotZone(Offset position) {
    return _isReturnToCursorHotZone(position);
  }

  void _onReturnButtonHoverChanged(bool hovered) {
    _scrollbarVisibility.setReturnButtonHovered(hovered);
  }

  void _onReturnToCursorInteractionStart() {
    _stopScrollInertia();
    _scrollAccumulator.reset();
  }

  void _returnToCursor() {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    _stopScrollInertia();
    _scrollAccumulator.reset();
    _scrollbarVisibility.showTemporarily();
    _terminalScrollController.followLatest();
    if (_terminalScrollController.hasClients) {
      final position = _terminalScrollController.position;
      if (position.hasContentDimensions) {
        _terminalScrollController.jumpTo(position.maxScrollExtent);
      }
    }
    // A ScrollPosition already at max does not emit another notification.
    // Explicitly activate Ghostty's live viewport as well, since the maximum
    // history offset and the active viewport are distinct terminal states.
    _requestTerminalViewport((
      offset: snapshot.maxViewportOffset,
      latest: true,
    ));
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
    _flushRemoteBytesToWorker();
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
    _flushRemoteBytesToWorker();
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

  void _stopScrollInertia() {
    if (!_terminalScrollController.hasClients) return;
    final position = _terminalScrollController.position;
    final target = position.pixels
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _terminalScrollController.jumpTo(target);
  }

  /// Extract the visible grid as text (rows joined by newlines, trailing
  /// whitespace trimmed). Used by long-press → copy.
  String _visibleText() {
    return _snapshot?.visibleText ?? '';
  }

  Future<void> _copySelectedText() async {
    if (!_initialized) return;
    final text = await _worker?.copySelection() ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showMotifToast(context, 'Copied selection');
    }
  }

  Future<void> _copyVisible() async {
    if (!_initialized) return;
    await _copySelectionOrVisible();
  }

  Future<void> _copySelectionOrVisible() async {
    if (!_initialized) return;
    final selection = _selection;
    final text = selection == null
        ? _visibleText()
        : await _worker?.copySelection() ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showMotifToast(
        context,
        selection == null ? 'Copied terminal output' : 'Copied selection',
      );
    }
  }
}

enum _TouchSelectionHandle { start, end }

enum _TerminalContextMenuAction { copy, paste }
