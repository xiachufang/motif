// Web terminal backed by libghostty compiled to WebAssembly (ghostty-vt.wasm),
// driven through the `window.GhosttyVt` JS bridge (web/ghostty_vt.js). The bytes
// from the remote PTY are fed into the wasm VT engine; the rendered grid is read
// back as text and painted as monospace rows. Input is provided by the composer
// (BottomInputBar), mirroring the mobile model.
//
// The JS call sequence (newTerminal → write → gridText) was verified end-to-end
// in Node against the same wasm module.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme/motif_theme.dart';
import 'terminal_error_view.dart';
import 'terminal_byte_batcher.dart';
import 'terminal_focus_policy.dart';
import 'terminal_fonts.dart';
import 'terminal_input.dart';
import 'terminal_key.dart';
import 'keyboard_chars.dart';
import 'terminal_palette.dart';
import 'terminal_scroll_driver.dart';
import 'terminal_scrollbar.dart';
import 'terminal_session.dart';

@JS('GhosttyVt')
external _GhosttyVt? get _ghosttyVt;

extension type _GhosttyVt(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> get ready;
  external int newTerminal(int cols, int rows);
  external void freeTerminal(int term);
  external void write(int term, JSUint8Array bytes);
  external String gridText(int term);
  external String gridCellsJson(int term);
  external void resize(
    int term,
    int cols,
    int rows,
    int cellWidth,
    int cellHeight,
  );
  external void scroll(int term, int delta);
  external void scrollToOffset(int term, int offset);
  external void scrollToBottom(int term);
  external JSUint8Array encodeKey(
    int term,
    int key,
    int action,
    int mods,
    String? text,
    int unshiftedCodepoint,
  );
  external JSUint8Array encodePaste(int term, JSUint8Array bytes);
}

Widget buildWebTerminal({
  required TerminalSession motif,
  required String ptyId,
  required double fontSize,
  required bool active,
  required int focusSerial,
  required TerminalPalette palette,
}) {
  if (_ghosttyVt == null) {
    return const TerminalErrorView(
      title: 'Ghostty terminal unavailable',
      message: 'The Ghostty WebAssembly bridge is missing.',
    );
  }
  return _WasmTerminalView(
    key: ValueKey('wasm-$ptyId'),
    motif: motif,
    ptyId: ptyId,
    fontSize: fontSize,
    active: active,
    focusSerial: focusSerial,
    palette: palette,
  );
}

class _WasmTerminalView extends StatefulWidget {
  final TerminalSession motif;
  final String ptyId;
  final double fontSize;
  final bool active;
  final int focusSerial;
  final TerminalPalette palette;
  const _WasmTerminalView({
    super.key,
    required this.motif,
    required this.ptyId,
    required this.fontSize,
    required this.active,
    required this.focusSerial,
    required this.palette,
  });

  @override
  State<_WasmTerminalView> createState() => _WasmTerminalViewState();
}

class _WasmTerminalViewState extends State<_WasmTerminalView> {
  static const double _padding = MotifSpacing.sm;
  static const int _maxPendingTerminalInputs = 256;

  int? _term;
  List<List<_Run>> _rows = const [];
  int _curX = -1, _curY = -1;
  int _scrollTotalRows = 0;
  int _scrollViewportRows = 0;
  int _viewportOffset = 0;
  bool _alternateScreenActive = false;
  int _cols = 80;
  int _gridRows = 24;
  double _cellWidth = 0;
  double _cellHeight = 0;
  bool _resizeScheduled = false;
  bool _failed = false;
  Object? _failure;
  final FocusNode _focusNode = FocusNode(debugLabel: 'Wasm terminal');
  final Set<LogicalKeyboardKey> _hostShortcutKeys = <LogicalKeyboardKey>{};
  final List<TerminalInputEvent> _pendingTerminalInputs =
      <TerminalInputEvent>[];
  final TerminalByteBatcher _pendingPtyBytes = TerminalByteBatcher();
  final TerminalScrollAccumulator _scrollAccumulator =
      TerminalScrollAccumulator();
  final TerminalScrollbarVisibilityController _scrollbarVisibility =
      TerminalScrollbarVisibilityController();
  Timer? _repaint;

  @override
  void initState() {
    super.initState();
    _measureCell();
    widget.motif.registerPtySink(widget.ptyId, _onBytes);
    widget.motif.registerTerminalInputSink(widget.ptyId, _onTerminalInput);
    _init();
    if (terminalAutofocusesOnTabSwitchByDefault()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _requestFocus());
    }
  }

  Future<void> _init() async {
    try {
      final ok = await _ghosttyVt!.ready.toDart;
      if (!ok.toDart) {
        if (mounted) setState(() => _failed = true);
        return;
      }
      if (!mounted) return;
      _term = _ghosttyVt!.newTerminal(80, 24);
      _flushPendingPtyBytes();
      _flushPendingTerminalInputs();
      unawaited(widget.motif.resizePty(widget.ptyId, 80, 24));
      if (widget.active) {
        unawaited(widget.motif.activatePtyStream(widget.ptyId));
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failure = e;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant _WasmTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ptyId != widget.ptyId) {
      oldWidget.motif.unregisterPtySink(oldWidget.ptyId, _onBytes);
      oldWidget.motif.unregisterTerminalInputSink(
        oldWidget.ptyId,
        _onTerminalInput,
      );
      widget.motif.registerPtySink(widget.ptyId, _onBytes);
      widget.motif.registerTerminalInputSink(widget.ptyId, _onTerminalInput);
    }
    if (oldWidget.fontSize != widget.fontSize) {
      _measureCell();
      _cols = 0;
      _gridRows = 0;
      _resizeScheduled = false;
    }
    final gainedActive = !oldWidget.active && widget.active;
    final shouldDefaultFocus =
        gainedActive && terminalAutofocusesOnTabSwitchByDefault();
    final focusRequested = oldWidget.focusSerial != widget.focusSerial;
    if (shouldDefaultFocus || focusRequested) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _requestFocus());
    }
    if (!oldWidget.active && widget.active) {
      unawaited(widget.motif.activatePtyStream(widget.ptyId));
    } else if (oldWidget.active && !widget.active) {
      _focusNode.unfocus();
      unawaited(widget.motif.deactivatePtyStream(widget.ptyId));
    }
  }

  void _requestFocus() {
    if (!mounted || !widget.active || !_focusNode.canRequestFocus) return;
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
  }

  void _onBytes(Uint8List bytes) {
    final t = _term;
    if (t == null) {
      if (!_pendingPtyBytes.add(bytes)) {
        _failed = true;
        _failure = StateError(
          'Web terminal replay exceeded ${_pendingPtyBytes.maxPendingBytes} bytes',
        );
      }
      return;
    }
    _ghosttyVt!.write(t, bytes.toJS);
    // Debounce re-reads of the grid.
    _repaint ??= Timer(const Duration(milliseconds: 16), () {
      _repaint = null;
      if (!mounted || _term == null) return;
      _refreshGrid();
    });
  }

  void _flushPendingPtyBytes() {
    final term = _term;
    if (term == null || _failed) return;
    for (final bytes in _pendingPtyBytes.drain()) {
      _ghosttyVt!.write(term, bytes.toJS);
    }
  }

  void _refreshGrid() {
    final term = _term;
    if (!mounted || term == null) return;
    final rows = _parseGrid(_ghosttyVt!.gridCellsJson(term));
    setState(() => _rows = rows);
  }

  List<List<_Run>> _parseGrid(String json) {
    try {
      final obj = jsonDecode(json) as Map<String, Object?>;
      final cursor = obj['cursor'] as Map?;
      if (cursor != null && (cursor['vis'] as bool? ?? false)) {
        _curX = (cursor['x'] as num?)?.toInt() ?? -1;
        _curY = (cursor['y'] as num?)?.toInt() ?? -1;
      } else {
        _curX = _curY = -1;
      }
      final scrollbar = obj['scrollbar'] as Map?;
      _scrollTotalRows = (scrollbar?['total'] as num?)?.toInt() ?? _rows.length;
      _viewportOffset = (scrollbar?['offset'] as num?)?.toInt() ?? 0;
      _scrollViewportRows =
          (scrollbar?['len'] as num?)?.toInt() ?? _rows.length;
      _alternateScreenActive = obj['alternateScreenActive'] as bool? ?? false;
      final hasScrollback =
          _scrollViewportRows > 0 &&
          _scrollTotalRows > _scrollViewportRows &&
          !_alternateScreenActive;
      _scrollbarVisibility.updateCanShow(hasScrollback);
      if (_isAtLatest || _alternateScreenActive) {
        _scrollbarVisibility.setReturnButtonHovered(false);
      }
      final rows = (obj['rows'] as List?) ?? const [];
      return [
        for (final row in rows)
          [
            for (final r in (row as List))
              _Run(
                (r as Map)['t'] as String? ?? '',
                _color(r['f']),
                _color(r['b']),
              ),
          ],
      ];
    } catch (_) {
      return const [];
    }
  }

  Color? _color(Object? rgb) {
    if (rgb is! List || rgb.length < 3) return null;
    return Color.fromARGB(
      255,
      (rgb[0] as num).toInt(),
      (rgb[1] as num).toInt(),
      (rgb[2] as num).toInt(),
    );
  }

  bool get _isAtLatest {
    final maxOffset = (_scrollTotalRows - _scrollViewportRows).clamp(
      0,
      _scrollTotalRows,
    );
    return _viewportOffset >= maxOffset;
  }

  bool get _usesMobileDirectTouchScroll =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  void _measureCell() {
    final font = platformTerminalFont();
    final painter = TextPainter(
      text: TextSpan(
        text: 'M',
        style: TextStyle(
          fontFamily: font.family,
          fontFamilyFallback: font.fallback,
          fontSize: widget.fontSize,
          height: 1.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _cellWidth = painter.width;
    _cellHeight = painter.height;
    painter.dispose();
  }

  void _scheduleResize(BoxConstraints constraints) {
    final term = _term;
    if (term == null || _cellWidth <= 0 || _cellHeight <= 0) return;
    final cols = ((constraints.maxWidth - 2 * _padding) / _cellWidth)
        .floor()
        .clamp(1, 1000);
    final rows = ((constraints.maxHeight - 2 * _padding) / _cellHeight)
        .floor()
        .clamp(1, 1000);
    if ((cols == _cols && rows == _gridRows) || _resizeScheduled) return;
    _resizeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resizeScheduled = false;
      if (!mounted || _term != term) return;
      _cols = cols;
      _gridRows = rows;
      _ghosttyVt!.resize(
        term,
        cols,
        rows,
        _cellWidth.round(),
        _cellHeight.round(),
      );
      unawaited(widget.motif.resizePty(widget.ptyId, cols, rows));
      _refreshGrid();
    });
  }

  void _scrollByPixels(double pixels) {
    if (_scrollTotalRows > _scrollViewportRows && !_alternateScreenActive) {
      _scrollbarVisibility.showTemporarily();
    }
    final rows = _scrollAccumulator.applyPixelDelta(pixels, _cellHeight);
    if (rows == 0 || _alternateScreenActive) return;
    final term = _term;
    if (term == null) return;
    _ghosttyVt!.scroll(term, rows);
    _refreshGrid();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _scrollByPixels(event.scrollDelta.dy);
    event.respond(allowPlatformDefault: false);
  }

  void _onReturnButtonHoverChanged(bool hovered) {
    _scrollbarVisibility.setReturnButtonHovered(hovered);
  }

  void _returnToCursor() {
    final term = _term;
    if (term == null) return;
    _scrollAccumulator.reset();
    _scrollbarVisibility.showTemporarily();
    _ghosttyVt!.scrollToBottom(term);
    _refreshGrid();
  }

  bool _onTerminalInput(TerminalInputEvent input) {
    final term = _term;
    if (_failed || !widget.motif.canInput) return false;
    if (input case TerminalPasteInput(:final bytes) when bytes.isEmpty) {
      return false;
    }
    if (input case TerminalKeyInput(
      :final keyId,
    ) when terminalKeySpecForId(keyId) == null) {
      return false;
    }
    if (term == null) {
      if (_pendingTerminalInputs.length >= _maxPendingTerminalInputs) {
        return false;
      }
      _pendingTerminalInputs.add(input);
      return true;
    }
    _dispatchTerminalInput(term, input);
    return true;
  }

  void _flushPendingTerminalInputs() {
    final term = _term;
    if (term == null || _failed) return;
    final pending = List<TerminalInputEvent>.of(_pendingTerminalInputs);
    _pendingTerminalInputs.clear();
    _pendingPtyBytes.clear();
    for (final input in pending) {
      _dispatchTerminalInput(term, input);
    }
  }

  void _dispatchTerminalInput(int term, TerminalInputEvent input) {
    switch (input) {
      case TerminalPasteInput(:final bytes):
        if (bytes.isEmpty) return;
        final encoded = _ghosttyVt!.encodePaste(term, bytes.toJS).toDart;
        if (encoded.isNotEmpty) widget.motif.writePty(widget.ptyId, encoded);
      case TerminalKeyInput():
        final key = terminalKeySpecForId(input.keyId);
        if (key == null) return;
        _encodeAndWriteKey(
          key,
          action: input.action,
          modifiers: input.modifiers,
        );
    }
  }

  void _encodeAndWriteKey(
    TerminalKeySpec key, {
    required TerminalKeyAction action,
    required TerminalKeyModifiers modifiers,
    String? eventCharacter,
  }) {
    final term = _term;
    if (term == null) return;
    final shift = modifiers.shift || key.implicitShift;
    final effectiveModifiers = TerminalKeyModifiers(
      shift: shift,
      ctrl: modifiers.ctrl,
      alt: modifiers.alt,
      meta: modifiers.meta,
    );
    final text = action == TerminalKeyAction.release
        ? null
        : logicalKeyEventCharacter(
            key.logicalKey,
            eventCharacter ?? key.character,
            shift: shift,
          );
    final encoded = _ghosttyVt!
        .encodeKey(
          term,
          key.ghosttyKey,
          action.ghosttyValue,
          effectiveModifiers.ghosttyMask,
          text,
          key.unshiftedCodepoint,
        )
        .toDart;
    if (encoded.isNotEmpty) widget.motif.writePty(widget.ptyId, encoded);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.motif.canInput || _term == null) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
    final hostShortcut = isTerminalHostShortcut(
      logicalKey: event.logicalKey,
      shift: hw.isShiftPressed,
      control: hw.isControlPressed,
      alt: hw.isAltPressed,
      meta: hw.isMetaPressed,
    );
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (hostShortcut) {
        _hostShortcutKeys.add(event.logicalKey);
        return KeyEventResult.ignored;
      }
    } else if (event is KeyUpEvent) {
      final wasHostShortcut = _hostShortcutKeys.remove(event.logicalKey);
      if (hostShortcut || wasHostShortcut) return KeyEventResult.ignored;
    } else {
      return KeyEventResult.ignored;
    }
    final key = terminalKeySpecForLogicalKey(
      event.logicalKey,
      character: event is KeyUpEvent ? null : event.character,
    );
    if (key == null) return KeyEventResult.ignored;
    final action = switch (event) {
      KeyDownEvent() => TerminalKeyAction.press,
      KeyRepeatEvent() => TerminalKeyAction.repeat,
      KeyUpEvent() => TerminalKeyAction.release,
      _ => throw StateError('unreachable key event'),
    };
    _encodeAndWriteKey(
      key,
      action: action,
      modifiers: TerminalKeyModifiers(
        shift: hw.isShiftPressed,
        ctrl: hw.isControlPressed,
        alt: hw.isAltPressed,
        meta: hw.isMetaPressed,
      ),
      eventCharacter: event is KeyUpEvent ? null : event.character,
    );
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    widget.motif.unregisterPtySink(widget.ptyId, _onBytes);
    widget.motif.unregisterTerminalInputSink(widget.ptyId, _onTerminalInput);
    unawaited(widget.motif.deactivatePtyStream(widget.ptyId));
    _repaint?.cancel();
    _pendingTerminalInputs.clear();
    _pendingPtyBytes.clear();
    final term = _term;
    _term = null;
    if (term != null) _ghosttyVt?.freeTerminal(term);
    _scrollbarVisibility.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    if (_failed) {
      return TerminalErrorView(
        title: 'Ghostty terminal failed to initialize',
        message: 'The WebAssembly terminal could not be started.',
        details: _failure?.toString(),
      );
    }
    if (_term == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final font = platformTerminalFont();
    final base = TextStyle(
      fontFamily: font.family,
      fontFamilyFallback: font.fallback,
      fontSize: widget.fontSize,
      color: widget.palette.foreground,
      height: 1.3,
    );
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.active && terminalAutofocusesOnTabSwitchByDefault(),
      canRequestFocus: widget.active,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _scheduleResize(constraints);
          return Listener(
            onPointerSignal: _onPointerSignal,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _requestFocus,
              onVerticalDragUpdate: _usesMobileDirectTouchScroll
                  ? (details) => _scrollByPixels(
                      touchMoveDeltaToScrollPixels(details.delta.dy),
                    )
                  : null,
              child: ColoredBox(
                color: widget.palette.background,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(_padding),
                      child: SelectionArea(
                        child: ListView.builder(
                          primary: false,
                          physics: const NeverScrollableScrollPhysics(),
                          itemExtent: _cellHeight > 0 ? _cellHeight : null,
                          itemCount: _rows.length,
                          itemBuilder: (_, i) => Text.rich(
                            _buildRow(
                              _rows[i],
                              i == _curY ? _curX : -1,
                              base,
                              c,
                              widget.palette,
                            ),
                          ),
                        ),
                      ),
                    ),
                    TerminalScrollControls(
                      totalRows: _scrollTotalRows,
                      visibleRows: _scrollViewportRows,
                      viewportOffset: _viewportOffset,
                      alternateScreenActive: _alternateScreenActive,
                      visibilityController: _scrollbarVisibility,
                      buttonForegroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurface,
                      buttonBackgroundColor: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.92),
                      onReturnButtonHoverChanged: _onReturnButtonHoverChanged,
                      onReturnToCursorInteractionStart:
                          _scrollAccumulator.reset,
                      onReturnToCursor: _returnToCursor,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Build a row's spans, inverting the single cell at [cursorCol] (or -1 for no
/// cursor on this row) to show the cursor block.
TextSpan _buildRow(
  List<_Run> runs,
  int cursorCol,
  TextStyle base,
  MotifColors c,
  TerminalPalette palette,
) {
  final spans = <TextSpan>[];
  var col = 0;
  for (final run in runs) {
    final style = base.copyWith(
      color: run.fg ?? c.textPrimary,
      backgroundColor: run.bg,
    );
    if (cursorCol < col || cursorCol >= col + run.text.length) {
      spans.add(TextSpan(text: run.text, style: style));
      col += run.text.length;
      continue;
    }
    // Split this run at the cursor cell.
    final rel = cursorCol - col;
    if (rel > 0) {
      spans.add(TextSpan(text: run.text.substring(0, rel), style: style));
    }
    final cursorChar = run.text.substring(rel, rel + 1);
    spans.add(
      TextSpan(
        text: cursorChar,
        style: style.copyWith(
          color: run.bg ?? palette.background,
          backgroundColor: c.accent,
        ),
      ),
    );
    if (rel + 1 < run.text.length) {
      spans.add(TextSpan(text: run.text.substring(rel + 1), style: style));
    }
    col += run.text.length;
  }
  // Cursor past end of line content.
  if (cursorCol >= col && cursorCol >= 0) {
    spans.add(
      TextSpan(
        text: ' ',
        style: base.copyWith(
          color: palette.background,
          backgroundColor: c.accent,
        ),
      ),
    );
  }
  return TextSpan(children: spans);
}

/// A run of same-styled cells in a terminal row.
class _Run {
  final String text;
  final Color? fg;
  final Color? bg;
  const _Run(this.text, this.fg, this.bg);
}
