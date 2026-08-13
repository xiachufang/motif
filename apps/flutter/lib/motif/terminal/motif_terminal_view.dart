/// The real libghostty-backed terminal surface for a remote Motif PTY.
///
/// Mirrors `lib/src/terminal_view.dart` (the local-PTY demo) but runs the
/// ghostty engine in *network mode*: bytes from the remote `/pty/<id>` stream
/// are fed via [TerminalState.feedBytes], and the engine's encoded input is
/// routed to [TerminalSession.writePty]. Grid resizes additionally issue an RPC
/// `pty.resize`.
///
/// Runtime requires the native libghostty asset (built with Zig). If the asset
/// is unavailable, the pane shows an explicit terminal error.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart' as cupertino;
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'ghostty_bindings.g.dart';
import 'key_map.dart';
import 'terminal_input.dart';
import 'terminal_key.dart';
import 'terminal_painter.dart';
import '../log/log.dart';
import 'terminal_error_view.dart';
import 'terminal_byte_batcher.dart';
import 'terminal_fonts.dart';
import 'terminal_focus_policy.dart';
import 'terminal_hyperlink.dart';
import 'terminal_link.dart';
import 'terminal_palette.dart';
import 'terminal_pointer_policy.dart';
import 'terminal_scroll_driver.dart';
import 'terminal_scrollbar.dart';
import 'terminal_snapshot.dart';
import 'terminal_session.dart';
import 'terminal_worker.dart';
import '../ui/theme/motif_theme.dart';
import '../ui/widgets/top_toast.dart';

part 'motif_terminal/text_input.dart';
part 'motif_terminal/core.dart';
part 'motif_terminal/keyboard_lift.dart';
part 'motif_terminal/key_events.dart';
part 'motif_terminal/pointer_input.dart';

class MotifTerminalView extends StatefulWidget {
  final TerminalSession motif;
  final String ptyId;
  final double fontSize;
  final String? fontFamily;
  final double padding;
  final bool active;
  final bool tabActive;
  final int focusSerial;
  final TerminalPalette palette;
  final ValueListenable<double> keyboardInset;
  final Future<void> Function(TerminalFileTarget target)? onOpenFile;

  const MotifTerminalView({
    super.key,
    required this.motif,
    required this.ptyId,
    this.fontSize = 13.0,
    this.fontFamily,
    this.padding = 4.0,
    required this.active,
    required this.tabActive,
    required this.focusSerial,
    required this.palette,
    required this.keyboardInset,
    this.onOpenFile,
  });

  @override
  State<MotifTerminalView> createState() => _MotifTerminalViewState();
}

class _MotifTerminalViewState extends State<MotifTerminalView>
    with TextInputClient {
  static const double _keyboardCursorMargin = 16;
  static const Duration _terminalInitDelay = Duration(milliseconds: 32);
  static const Duration _remoteByteCoalesceDelay = Duration(milliseconds: 8);
  static const Duration _interactiveEchoWindow = Duration(milliseconds: 150);
  static const int _maxPendingTerminalInputs = 256;
  static const _softKeyboardSeed = '\u200b';
  static const _softKeyboardValue = TextEditingValue(
    text: _softKeyboardSeed,
    selection: TextSelection.collapsed(offset: _softKeyboardSeed.length),
  );

  TerminalWorkerClient? _worker;
  Timer? _resizeTimer;
  Timer? _terminalInitTimer;
  Timer? _remoteByteFlushTimer;
  final Set<LogicalKeyboardKey> _hostShortcutKeys = <LogicalKeyboardKey>{};
  final Set<PhysicalKeyboardKey> _textInputOwnedKeys = <PhysicalKeyboardKey>{};
  final TerminalScrollController _terminalScrollController =
      TerminalScrollController(
        debugLabel: 'Motif terminal scroll position',
        keepScrollOffset: false,
      );
  TerminalViewportTarget? _pendingViewportRequest;
  int? _touchScrollPointer;
  int? _touchSelectionPointer;
  PointerDeviceKind? _lastPointerKind;
  Offset? _lastPointerPosition;
  Offset? _touchDownPosition;
  TerminalSnapshot? _touchDownSnapshot;
  TerminalCellPoint? _touchDownCell;
  bool _suppressNextTerminalTap = false;
  double _touchScrollDistance = 0;
  final TerminalScrollAccumulator _scrollAccumulator =
      TerminalScrollAccumulator();
  final TerminalScrollbarVisibilityController _scrollbarVisibility =
      TerminalScrollbarVisibilityController();
  final Set<int> _terminalOverlayPointers = <int>{};
  final Map<int, ({TerminalLinkMatch match, Offset downPosition})>
  _terminalHyperlinkPointers =
      <int, ({TerminalLinkMatch match, Offset downPosition})>{};
  TerminalLinkMatch? _hoveredTerminalLink;
  TerminalCellPoint? _terminalLinkHoverCell;
  int? _terminalLinkHoverFrameId;
  bool _terminalLinkMode = false;
  late final bool Function(KeyEvent) _terminalLinkKeyboardHandler;
  int? _terminalContextMenuPointer;
  final FocusNode _focusNode = FocusNode(debugLabel: 'Motif terminal');
  final GlobalKey _terminalSurfaceKey = GlobalKey(
    debugLabel: 'Motif terminal surface',
  );
  final ValueNotifier<double> _keyboardLiftOffset = ValueNotifier(0);
  TextInputConnection? _textInputConnection;
  TextEditingValue _textInputValue = _softKeyboardValue;
  String? _composingText;
  _CursorSnapshot? _lastCursorSnapshot;
  bool _showSoftKeyboardOnFocus = false;

  double _cellWidth = 0;
  double _cellHeight = 0;
  double _viewportWidth = 0;
  double _viewportHeight = 0;
  int _cols = 80;
  int _rows = 24;
  BoxConstraints? _pendingInitConstraints;
  int? _pendingResizeCols;
  int? _pendingResizeRows;
  bool _initialized = false;
  bool _workerStarting = false;
  bool _workerNeedsColdResync = false;
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
  final TerminalByteBatcher _remoteByteBatcher = TerminalByteBatcher();
  final List<TerminalInputEvent> _pendingTerminalInputs =
      <TerminalInputEvent>[];
  DateTime? _lastHostWriteAt;
  TerminalSnapshot? _snapshot;
  ({int generation, TerminalSnapshot snapshot, void Function() acknowledge})?
  _pendingFrameSnapshot;
  bool _snapshotFrameScheduled = false;
  TerminalSelection? _selection;
  TerminalCellPoint? _mouseSelectionAnchor;
  int? _mouseSelectionPointer;
  Offset? _mouseSelectionDownPosition;
  bool _mouseSelectionStarted = false;
  bool _touchSelectionActive = false;
  bool _touchSelectionGestureActive = false;
  bool _tapStartedWithSelection = false;
  _TouchSelectionHandle? _touchSelectionDragHandle;
  OverlayEntry? _touchSelectionHandlesEntry;
  OverlayEntry? _touchSelectionMenuEntry;
  int _remoteChunks = 0;
  int _remoteBytes = 0;
  int _scrollDiagnosticSequence = 0;
  DateTime? _lastScrollDiagnosticLogAt;
  final TerminalRenderCache _terminalRenderCache = TerminalRenderCache();

  void _logScrollDiagnostic(
    String stage, {
    String detail = '',
    bool force = false,
  }) {
    final sequence = ++_scrollDiagnosticSequence;
    final now = DateTime.now();
    final last = _lastScrollDiagnosticLogAt;
    if (!force &&
        sequence > 40 &&
        last != null &&
        now.difference(last) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastScrollDiagnosticLogAt = now;
    final snapshot = _snapshot;
    var controller = 'detached';
    if (_terminalScrollController.hasClients) {
      final position = _terminalScrollController.position;
      controller = position.hasContentDimensions
          ? '${position.pixels.toStringAsFixed(2)}/'
                '${position.maxScrollExtent.toStringAsFixed(2)} '
                'scrolling=${position.isScrollingNotifier.value}'
          : 'attached-no-dimensions';
    }
    Log.i(
      'scroll#$sequence stage=$stage pty=${widget.ptyId} '
      'initialized=$_initialized error=${_terminalError != null} '
      'controller=$controller '
      'snapshot=${snapshot == null ? 'none' : '${snapshot.viewportOffset}/${snapshot.maxViewportOffset}'} '
      'active=${snapshot?.viewportActive} history=${snapshot?.hasScrollback} '
      'overscan=${snapshot == null ? 'none' : '${snapshot.topOverscanRows}/${snapshot.bottomOverscanRows}'} '
      'pending=$_pendingViewportRequest '
      '$detail',
      name: 'motif.terminal.scroll',
    );
  }

  TerminalViewportProjection? get _viewportProjection {
    final snapshot = _snapshot;
    if (snapshot == null || _cellHeight <= 0) return null;
    var scrollPixels = snapshot.viewportOffset * _cellHeight;
    var maxScrollPixels = snapshot.maxViewportOffset * _cellHeight;
    if (_terminalScrollController.hasClients) {
      final position = _terminalScrollController.position;
      if (position.hasContentDimensions) {
        scrollPixels = position.pixels;
        maxScrollPixels = position.maxScrollExtent;
      }
    }
    return TerminalViewportProjection.calculate(
      scrollPixels: scrollPixels,
      rowHeight: _cellHeight,
      maxViewportOffset: (maxScrollPixels / _cellHeight).round(),
      maxScrollPixels: maxScrollPixels,
      snapshotViewportOffset: snapshot.viewportOffset,
      snapshotIsLive: snapshot.viewportActive,
      followsLatest: _terminalScrollController.followsLatest,
    );
  }

  double get _visualViewportOffset =>
      _viewportProjection?.visualRowOffset ??
      _snapshot?.viewportOffset.toDouble() ??
      0;

  double get _viewportPixelOffset => _viewportProjection?.paintOffset ?? 0;

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
    _terminalScrollController.addListener(_onTerminalScrollPositionChanged);
    _terminalLinkKeyboardHandler = _onTerminalLinkHardwareEvent;
    HardwareKeyboard.instance.addHandler(_terminalLinkKeyboardHandler);
    _focusNode.addListener(_onFocusChanged);
    widget.keyboardInset.addListener(_syncKeyboardLift);
    _measureCell();
    Log.i(
      'terminal initState pty=${widget.ptyId} active=${widget.active}',
      name: 'motif.terminal',
    );
    widget.motif.registerPtySink(widget.ptyId, _onRemoteBytes);
    widget.motif.registerTerminalInputSink(widget.ptyId, _onTerminalInput);
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
      final visualViewportOffset = _visualViewportOffset;
      _measureCell();
      _scheduleResizeAndMaybeOpen();
      _scheduleTerminalScrollPositionRestore(visualViewportOffset);
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
      widget.motif.unregisterTerminalInputSink(
        oldWidget.ptyId,
        _onTerminalInput,
      );
      unawaited(widget.motif.deactivatePtyStream(oldWidget.ptyId));
      widget.motif.registerPtySink(widget.ptyId, _onRemoteBytes);
      widget.motif.registerTerminalInputSink(widget.ptyId, _onTerminalInput);
    }
    if (oldWidget.active != widget.active) {
      Log.i(
        'terminal active changed pty=${widget.ptyId} active=${widget.active}',
        name: 'motif.terminal',
      );
      _invalidateStreamWork();
      if (!widget.active) {
        _setTerminalLinkMode(false);
        _showSoftKeyboardOnFocus = false;
        _focusNode.unfocus();
        _closeTextInput();
      }
      _syncKeyboardLift();
    }
    if (oldWidget.tabActive && !widget.tabActive) {
      _clearTerminalSelection();
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
    widget.motif.unregisterTerminalInputSink(widget.ptyId, _onTerminalInput);
    _resizeTimer?.cancel();
    _terminalInitTimer?.cancel();
    _remoteByteFlushTimer?.cancel();
    _retryTimer?.cancel();
    _pendingFrameSnapshot?.acknowledge();
    _pendingFrameSnapshot = null;
    _remoteByteBatcher.clear();
    _pendingTerminalInputs.clear();
    _terminalHyperlinkPointers.clear();
    HardwareKeyboard.instance.removeHandler(_terminalLinkKeyboardHandler);
    _stopScrollInertia();
    _terminalScrollController.removeListener(_onTerminalScrollPositionChanged);
    _terminalScrollController.dispose();
    _discardTerminalSelectionState();
    _terminalRenderCache.dispose();
    unawaited(widget.motif.deactivatePtyStream(widget.ptyId));
    _focusNode.removeListener(_onFocusChanged);
    widget.keyboardInset.removeListener(_syncKeyboardLift);
    _closeTextInput();
    _keyboardLiftOffset.dispose();
    _scrollbarVisibility.dispose();
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
      // Render the in-progress composition inline at the cursor; nothing is
      // sent to the PTY until it commits.
      final raw = composing
          .textInside(value.text)
          .replaceAll(_softKeyboardSeed, '');
      _setComposingText(raw.isEmpty ? null : raw);
      _scheduleImeRectSync();
      return;
    }
    _setComposingText(null);

    // Enter is owned solely by performAction(newline). With
    // TextInputAction.newline some platforms (notably iOS) ALSO insert the
    // newline into the editing value here, which would emit a second carriage
    // return — the iOS "double newline". Strip line breaks so a Return produces
    // exactly one CR (via performAction).
    final committed = value.text
        .replaceAll(_softKeyboardSeed, '')
        .replaceAll('\n', '')
        .replaceAll('\r', '');
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
    _showSoftKeyboardOnFocus = false;
    _setComposingText(null);
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
    _terminalScrollController.autoFollowThresholdPixels =
        _cellHeight * terminalAutoFollowThresholdRows;
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
          child: Scrollable(
            controller: _terminalScrollController,
            // Match Ghostty: zero is the oldest row and the maximum is the
            // active terminal area.
            axisDirection: AxisDirection.down,
            viewportBuilder: (context, position) {
              return _TerminalScrollViewport(
                offset: position,
                maxScrollExtent: _terminalScrollMaxExtent,
                scrollIdentity: widget.ptyId,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _onTerminalTap,
                  onTapCancel: _onTerminalTapCancel,
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
                  child: MouseRegion(
                    cursor: _terminalMouseCursor,
                    onHover: _onPointerHover,
                    onExit: _onPointerExit,
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
                          final viewportWidth = constraints.maxWidth;
                          final viewportHeight = constraints.maxHeight;
                          final hadViewportSize =
                              _viewportWidth > 0 && _viewportHeight > 0;
                          final viewportSizeChanged =
                              hadViewportSize &&
                              ((_viewportWidth - viewportWidth).abs() >= 0.5 ||
                                  (_viewportHeight - viewportHeight).abs() >=
                                      0.5);
                          _viewportWidth = viewportWidth;
                          if ((_viewportHeight - viewportHeight).abs() >= 0.5) {
                            _viewportHeight = viewportHeight;
                            _scheduleKeyboardLiftSync();
                            _scheduleImeRectSync();
                          }
                          final font = _fontSpec;
                          final snapshot = _snapshot;
                          if (!_initialized) {
                            _scheduleTerminalInit(constraints);
                          }
                          if (snapshot == null) {
                            return ColoredBox(color: widget.palette.background);
                          }
                          if (_initialized) {
                            _handleResize(
                              constraints,
                              viewportSizeChanged: viewportSizeChanged,
                            );
                          }
                          final colorScheme = Theme.of(context).colorScheme;
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              CustomPaint(
                                painter: TerminalSnapshotPainter(
                                  snapshot: snapshot,
                                  viewportPixelOffset: _viewportPixelOffset,
                                  cellWidth: _cellWidth,
                                  cellHeight: _cellHeight,
                                  padding: widget.padding,
                                  fontFamily: font.family,
                                  fontFamilyFallback: font.fallback,
                                  fontSize: widget.fontSize,
                                  showCursor: _focusNode.hasFocus,
                                  selection: _selection,
                                  selectionBackground: colorScheme.primary
                                      .withValues(alpha: 0.72),
                                  selectionForeground: colorScheme.onPrimary,
                                  renderCache: _terminalRenderCache,
                                  preeditText: _composingText,
                                  linkSegments:
                                      _hoveredTerminalLink?.segments ??
                                      const [],
                                  linkUnderlineColor: colorScheme.primary,
                                ),
                                size: Size(
                                  constraints.maxWidth,
                                  constraints.maxHeight,
                                ),
                              ),
                              TerminalScrollControls(
                                totalRows: snapshot.scrollTotalRows,
                                visibleRows: snapshot.scrollViewportRows,
                                isAtLatest: snapshot.isAtLatest,
                                alternateScreenActive:
                                    snapshot.alternateScreenActive,
                                visibilityController: _scrollbarVisibility,
                                buttonForegroundColor: colorScheme.onSurface,
                                buttonBackgroundColor: colorScheme.surface
                                    .withValues(alpha: 0.92),
                                onReturnButtonHoverChanged:
                                    _onReturnButtonHoverChanged,
                                onReturnToCursorInteractionStart:
                                    _onReturnToCursorInteractionStart,
                                onReturnToCursor: _returnToCursor,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
      builder: (context, lift, child) =>
          Transform.translate(offset: Offset(0, -lift), child: child),
    );
  }
}

/// Supplies Flutter's [Scrollable] with terminal content dimensions while
/// leaving painting to [TerminalSnapshotPainter]. This lets the standard
/// ScrollPosition, gesture recognizers, velocity tracker, and platform physics
/// own the interaction without translating the terminal widget itself.
class _TerminalScrollViewport extends SingleChildRenderObjectWidget {
  final ViewportOffset offset;
  final double maxScrollExtent;
  final Object scrollIdentity;

  const _TerminalScrollViewport({
    required this.offset,
    required this.maxScrollExtent,
    required this.scrollIdentity,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderTerminalScrollViewport(
      offset,
      maxScrollExtent,
      scrollIdentity,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTerminalScrollViewport renderObject,
  ) {
    renderObject
      ..offset = offset
      ..maxScrollExtent = maxScrollExtent
      ..scrollIdentity = scrollIdentity;
  }
}

class _RenderTerminalScrollViewport extends RenderProxyBox {
  _RenderTerminalScrollViewport(
    this._offset,
    this._maxScrollExtent,
    this._scrollIdentity,
  );

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (identical(value, _offset)) return;
    _offset = value;
    markNeedsLayout();
  }

  double _maxScrollExtent;
  set maxScrollExtent(double value) {
    if (value == _maxScrollExtent) return;
    _maxScrollExtent = value;
    markNeedsLayout();
  }

  Object _scrollIdentity;
  bool _initialBottomApplied = false;
  set scrollIdentity(Object value) {
    if (value == _scrollIdentity) return;
    _scrollIdentity = value;
    _initialBottomApplied = false;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    _offset.applyViewportDimension(size.height);
    var contentDimensionsAccepted = _offset.applyContentDimensions(
      0,
      _maxScrollExtent,
    );
    // A new terminal starts in Ghostty's active area, which is the maximum on
    // the shared forward axis. Publish the new extent before the fallback
    // correction: follow-latest physics may already have moved pixels to the
    // bottom, and correcting first would make that extent delta apply twice.
    final applyInitialBottom = !_initialBottomApplied && _maxScrollExtent > 0;
    var correctedToInitialBottom = false;
    if (applyInitialBottom && _offset.hasPixels) {
      final correction = _maxScrollExtent - _offset.pixels;
      if (correction.abs() > precisionErrorTolerance) {
        _offset.correctBy(correction);
        correctedToInitialBottom = true;
      }
      if (_maxScrollExtent > 0) _initialBottomApplied = true;
    }
    // Unlike RenderViewport, this proxy has no offset-dependent child layout
    // to repeat. It still must let ScrollPosition accept dimensions again
    // after either physics or the initial-bottom fallback corrected pixels.
    if (!contentDimensionsAccepted || correctedToInitialBottom) {
      contentDimensionsAccepted = _offset.applyContentDimensions(
        0,
        _maxScrollExtent,
      );
      assert(contentDimensionsAccepted);
    }
  }
}
