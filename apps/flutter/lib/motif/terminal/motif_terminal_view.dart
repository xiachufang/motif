/// The real libghostty-backed terminal surface for a remote Motif PTY.
///
/// Mirrors `lib/src/terminal_view.dart` (the local-PTY demo) but runs the
/// ghostty engine in *network mode*: bytes from the remote `/pty/<id>` stream
/// are fed via [TerminalState.feedBytes], and the engine's encoded input is
/// routed to [MotifClient.writePty]. Grid resizes additionally issue an RPC
/// `pty.resize`.
///
/// Runtime requires the native libghostty asset (built with Zig). If the asset
/// is unavailable, the pane shows an explicit terminal error.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' as cupertino;
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'ghostty_bindings.g.dart';
import 'key_map.dart';
import 'terminal_painter.dart';
import '../log/log.dart';
import '../state/motif_client.dart';
import 'terminal_error_view.dart';
import 'terminal_fonts.dart';
import 'terminal_focus_policy.dart';
import 'terminal_palette.dart';
import 'terminal_paste.dart';
import 'terminal_scroll_driver.dart';
import 'terminal_snapshot.dart';
import 'terminal_worker.dart';

part 'motif_terminal/text_input.dart';
part 'motif_terminal/core.dart';
part 'motif_terminal/keyboard_lift.dart';
part 'motif_terminal/key_events.dart';
part 'motif_terminal/pointer_input.dart';

class MotifTerminalView extends StatefulWidget {
  final MotifClient motif;
  final String ptyId;
  final double fontSize;
  final String? fontFamily;
  final double padding;
  final bool active;
  final int focusSerial;
  final TerminalPalette palette;
  final ValueListenable<double> keyboardInset;

  const MotifTerminalView({
    super.key,
    required this.motif,
    required this.ptyId,
    this.fontSize = 13.0,
    this.fontFamily,
    this.padding = 4.0,
    required this.active,
    required this.focusSerial,
    required this.palette,
    required this.keyboardInset,
  });

  @override
  State<MotifTerminalView> createState() => _MotifTerminalViewState();
}

class _MotifTerminalViewState extends State<MotifTerminalView>
    with SingleTickerProviderStateMixin, TextInputClient {
  static const double _keyboardCursorMargin = 16;
  static const Duration _terminalInitDelay = Duration(milliseconds: 32);
  static const _softKeyboardSeed = '\u200b';
  static const _softKeyboardValue = TextEditingValue(
    text: _softKeyboardSeed,
    selection: TextSelection.collapsed(offset: _softKeyboardSeed.length),
  );

  TerminalWorkerClient? _worker;
  Timer? _resizeTimer;
  Timer? _terminalInitTimer;
  Ticker? _scrollTicker;
  Simulation? _scrollSimulation;
  Duration? _scrollSimulationStart;
  double _scrollSimulationLastPosition = 0;
  double _scrollVelocity = 0;
  Duration? _lastScrollUpdateTime;
  int? _touchScrollPointer;
  int? _touchSelectionPointer;
  PointerDeviceKind? _lastPointerKind;
  Offset? _lastPointerPosition;
  Offset? _touchDownPosition;
  double _touchScrollDistance = 0;
  final TerminalScrollAccumulator _scrollAccumulator =
      TerminalScrollAccumulator();
  final FocusNode _focusNode = FocusNode(debugLabel: 'Motif terminal');
  final GlobalKey _terminalSurfaceKey = GlobalKey(
    debugLabel: 'Motif terminal surface',
  );
  final ValueNotifier<double> _keyboardLiftOffset = ValueNotifier(0);
  TextInputConnection? _textInputConnection;
  TextEditingValue _textInputValue = _softKeyboardValue;
  _CursorSnapshot? _lastCursorSnapshot;
  bool _showSoftKeyboardOnFocus = false;

  double _cellWidth = 0;
  double _cellHeight = 0;
  double _viewportHeight = 0;
  int _cols = 80;
  int _rows = 24;
  BoxConstraints? _pendingInitConstraints;
  int? _pendingResizeCols;
  int? _pendingResizeRows;
  bool _initialized = false;
  bool _workerStarting = false;
  int _workerGeneration = 0;
  int _streamGeneration = 0;
  Object? _terminalError;
  StackTrace? _terminalStack;
  Timer? _retryTimer;
  int _terminalRetryAttempt = 0;
  bool _keyboardLiftSyncScheduled = false;
  bool _imeRectSyncScheduled = false;
  double _bottomViewPadding = 0;
  _KeyboardLiftTrace? _lastKeyboardLiftTrace;
  DateTime? _lastKeyboardLiftLogAt;
  final Queue<Uint8List> _remoteByteQueue = Queue<Uint8List>();
  int _remoteByteQueueBytes = 0;
  TerminalSnapshot? _snapshot;
  TerminalSelection? _selection;
  TerminalCellPoint? _mouseSelectionAnchor;
  int? _mouseSelectionPointer;
  TerminalCellPoint? _touchSelectionAnchor;
  bool _touchSelectionActive = false;
  bool _touchSelectionGestureActive = false;
  _TouchSelectionHandle? _touchSelectionDragHandle;
  OverlayEntry? _touchSelectionHandlesEntry;
  OverlayEntry? _touchSelectionMenuEntry;
  int _remoteChunks = 0;
  int _remoteBytes = 0;

  TerminalFontSpec get _fontSpec {
    final explicit = widget.fontFamily;
    if (explicit != null && explicit.isNotEmpty) {
      return TerminalFontSpec(explicit);
    }
    return platformTerminalFont();
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    widget.keyboardInset.addListener(_syncKeyboardLift);
    _measureCell();
    Log.i(
      'terminal initState pty=${widget.ptyId} active=${widget.active}',
      name: 'motif.terminal',
    );
    widget.motif.registerPtySink(widget.ptyId, _onRemoteBytes);
    if (terminalAutofocusesOnTabSwitchByDefault()) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _requestFocusWithoutKeyboard(),
      );
    }
  }

  @override
  void didUpdateWidget(covariant MotifTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyboardInset != widget.keyboardInset) {
      oldWidget.keyboardInset.removeListener(_syncKeyboardLift);
      widget.keyboardInset.addListener(_syncKeyboardLift);
      _syncKeyboardLift();
    }
    if (oldWidget.fontSize != widget.fontSize ||
        oldWidget.fontFamily != widget.fontFamily) {
      _measureCell();
      _scheduleResizeAndMaybeOpen();
    }
    if (oldWidget.palette != widget.palette) {
      _worker?.setThemeColors(
        foregroundArgb: _colorToArgb(widget.palette.foreground),
        backgroundArgb: _colorToArgb(widget.palette.background),
      );
    }
    if (oldWidget.ptyId != widget.ptyId) {
      Log.i(
        'terminal pty changed old=${oldWidget.ptyId} new=${widget.ptyId}',
        name: 'motif.terminal',
      );
      _invalidateStreamWork();
      _restartWorkerForNewPty();
      widget.motif.unregisterPtySink(oldWidget.ptyId, _onRemoteBytes);
      unawaited(widget.motif.deactivatePtyStream(oldWidget.ptyId));
      widget.motif.registerPtySink(widget.ptyId, _onRemoteBytes);
    }
    if (oldWidget.active != widget.active) {
      Log.i(
        'terminal active changed pty=${widget.ptyId} active=${widget.active}',
        name: 'motif.terminal',
      );
      _invalidateStreamWork();
      if (!widget.active) {
        _showSoftKeyboardOnFocus = false;
        _focusNode.unfocus();
        _closeTextInput();
      }
      _syncKeyboardLift();
    }
    if ((!oldWidget.active && widget.active) &&
        terminalAutofocusesOnTabSwitchByDefault()) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _requestFocusWithoutKeyboard(),
      );
    }
    if (oldWidget.focusSerial != widget.focusSerial) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _requestFocusWithoutKeyboard(),
      );
    }
    if (!oldWidget.active && widget.active) {
      _scheduleResizeAndMaybeOpen();
    }
  }

  @override
  void dispose() {
    _invalidateStreamWork();
    Log.i(
      'terminal dispose pty=${widget.ptyId} active=${widget.active} '
      'initialized=$_initialized chunks=$_remoteChunks bytes=$_remoteBytes',
      name: 'motif.terminal',
    );
    // Only drop the sink if it is still ours. When the pane subtree is rebuilt,
    // the replacement State's initState runs (and re-registers its sink) BEFORE
    // this dispose; an unconditional remove would clobber that live sink,
    // killing both the buffered replay and ongoing output for the new grid.
    widget.motif.unregisterPtySink(widget.ptyId, _onRemoteBytes);
    _resizeTimer?.cancel();
    _terminalInitTimer?.cancel();
    _retryTimer?.cancel();
    _remoteByteQueue.clear();
    _remoteByteQueueBytes = 0;
    _stopScrollInertia(resetVelocity: true);
    _scrollTicker?.dispose();
    _discardTerminalSelectionState();
    unawaited(widget.motif.deactivatePtyStream(widget.ptyId));
    _focusNode.removeListener(_onFocusChanged);
    widget.keyboardInset.removeListener(_syncKeyboardLift);
    _closeTextInput();
    _keyboardLiftOffset.dispose();
    _focusNode.dispose();
    unawaited(_worker?.dispose());
    super.dispose();
  }

  @override
  TextEditingValue? get currentTextEditingValue => _textInputValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    final previous = _textInputValue;
    _textInputValue = value;
    final previousComposing = previous.composing;
    final hadComposing =
        previousComposing.isValid && !previousComposing.isCollapsed;
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _scheduleImeRectSync();
      return;
    }

    final committed = value.text.replaceAll(_softKeyboardSeed, '');
    if (committed.isNotEmpty) {
      _writeSoftKeyboardText(committed);
    } else if (_usesSoftKeyboard &&
        !hadComposing &&
        value.text.length < previous.text.length) {
      _writeSoftKeyboardBytes(const [0x7f]);
    }
    _resetTextInputValue();
    _scheduleImeRectSync();
  }

  @override
  void performAction(TextInputAction action) {
    switch (action) {
      case TextInputAction.newline:
      case TextInputAction.done:
      case TextInputAction.go:
      case TextInputAction.send:
        _writeSoftKeyboardBytes(const [0x0d]);
      case TextInputAction.unspecified:
      case TextInputAction.none:
      case TextInputAction.search:
      case TextInputAction.next:
      case TextInputAction.previous:
      case TextInputAction.continueAction:
      case TextInputAction.join:
      case TextInputAction.route:
      case TextInputAction.emergencyCall:
        break;
    }
    _resetTextInputValue();
    _textInputConnection?.show();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _textInputConnection = null;
    _textInputValue = _softKeyboardValue;
    _showSoftKeyboardOnFocus = false;
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final error = _terminalError;
    if (error != null) {
      return TerminalErrorView(
        title: 'Ghostty terminal failed',
        message:
            'The native terminal could not be initialized or activated. '
            'Retrying automatically…',
        details: '$error\n$_terminalStack',
        onRetry: _retryTerminal,
      );
    }
    final bottomViewPadding = MediaQuery.viewPaddingOf(context).bottom;
    if ((_bottomViewPadding - bottomViewPadding).abs() >= 0.5) {
      _bottomViewPadding = bottomViewPadding;
      _scheduleKeyboardLiftSync();
    }
    final useTouchSelectionGestures = _usesTouchSelectionGestures;
    return ValueListenableBuilder<double>(
      valueListenable: _keyboardLiftOffset,
      child: RepaintBoundary(
        key: _terminalSurfaceKey,
        child: Focus(
          focusNode: _focusNode,
          autofocus: widget.active && terminalAutofocusesOnTabSwitchByDefault(),
          canRequestFocus: widget.active && widget.motif.canInput,
          onKeyEvent: _onKeyEvent,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleFocus,
            onLongPressStart: useTouchSelectionGestures
                ? _onTerminalLongPressStart
                : null,
            onLongPressMoveUpdate: useTouchSelectionGestures
                ? _onTerminalLongPressMoveUpdate
                : null,
            onLongPressEnd: useTouchSelectionGestures
                ? _onTerminalLongPressEnd
                : null,
            onLongPressCancel: useTouchSelectionGestures
                ? _onTerminalLongPressCancel
                : null,
            child: Listener(
              onPointerDown: _onPointerDown,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              onPointerMove: _onPointerMove,
              onPointerSignal: _onPointerSignal,
              onPointerPanZoomStart: _onPanZoomStart,
              onPointerPanZoomUpdate: _onPanZoomUpdate,
              onPointerPanZoomEnd: _onPanZoomEnd,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewportHeight = constraints.maxHeight;
                  if ((_viewportHeight - viewportHeight).abs() >= 0.5) {
                    _viewportHeight = viewportHeight;
                    _scheduleKeyboardLiftSync();
                    _scheduleImeRectSync();
                  }
                  final font = _fontSpec;
                  final snapshot = _snapshot;
                  if (!_initialized || snapshot == null) {
                    _scheduleTerminalInit(constraints);
                    return ColoredBox(color: widget.palette.background);
                  }
                  _handleResize(constraints);
                  final colorScheme = Theme.of(context).colorScheme;
                  return CustomPaint(
                    painter: TerminalSnapshotPainter(
                      snapshot: snapshot,
                      cellWidth: _cellWidth,
                      cellHeight: _cellHeight,
                      padding: widget.padding,
                      fontFamily: font.family,
                      fontFamilyFallback: font.fallback,
                      fontSize: widget.fontSize,
                      showCursor: _focusNode.hasFocus,
                      selection: _selection,
                      selectionBackground: colorScheme.primary.withValues(
                        alpha: 0.72,
                      ),
                      selectionForeground: colorScheme.onPrimary,
                    ),
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      builder: (context, lift, child) =>
          Transform.translate(offset: Offset(0, -lift), child: child),
    );
  }
}
