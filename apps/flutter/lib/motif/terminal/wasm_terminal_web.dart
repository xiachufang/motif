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
import 'terminal_focus_policy.dart';
import 'terminal_fonts.dart';
import 'terminal_input.dart';
import 'terminal_palette.dart';
import 'terminal_scroll_driver.dart';
import 'terminal_scrollbar.dart';
import 'terminal_session.dart';
import 'web_key_encoder.dart';

@JS('GhosttyVt')
external _GhosttyVt? get _ghosttyVt;

extension type _GhosttyVt(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> get ready;
  external int newTerminal(int cols, int rows);
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
      _term = _ghosttyVt!.newTerminal(80, 24);
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
    if (t == null) return;
    _ghosttyVt!.write(t, bytes.toJS);
    // Debounce re-reads of the grid.
    _repaint ??= Timer(const Duration(milliseconds: 16), () {
      _repaint = null;
      if (!mounted || _term == null) return;
      _refreshGrid();
    });
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

  void _onScrollbarHoverChanged(bool hovered) {
    _scrollbarVisibility.setHovered(hovered);
  }

  void _onReturnButtonHoverChanged(bool hovered) {
    _scrollbarVisibility.setReturnButtonHovered(hovered);
  }

  void _onScrollbarActivity() {
    _scrollAccumulator.reset();
    _scrollbarVisibility.showTemporarily();
  }

  void _onScrollbarDragStart() {
    _scrollAccumulator.reset();
    _scrollbarVisibility.beginDrag();
  }

  void _onScrollbarDragEnd() {
    _scrollbarVisibility.endDrag();
  }

  void _scrollToOffset(int offset) {
    final term = _term;
    if (term == null) return;
    _ghosttyVt!.scrollToOffset(term, offset);
    _refreshGrid();
  }

  void _returnToCursor() {
    final term = _term;
    if (term == null) return;
    _scrollAccumulator.reset();
    _scrollbarVisibility.showTemporarily();
    _ghosttyVt!.scrollToBottom(term);
    _refreshGrid();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
    if (isTerminalHostShortcut(
      logicalKey: event.logicalKey,
      shift: hw.isShiftPressed,
      control: hw.isControlPressed,
      alt: hw.isAltPressed,
      meta: hw.isMetaPressed,
    )) {
      return KeyEventResult.ignored;
    }
    final bytes = encodeKeyToBytes(
      event.logicalKey,
      event.character,
      TerminalKeyMods(
        ctrl: hw.isControlPressed,
        alt: hw.isAltPressed,
        shift: hw.isShiftPressed,
      ),
    );
    if (bytes == null || bytes.isEmpty) return KeyEventResult.ignored;
    widget.motif.writePty(widget.ptyId, bytes);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    widget.motif.unregisterPtySink(widget.ptyId);
    unawaited(widget.motif.deactivatePtyStream(widget.ptyId));
    _repaint?.cancel();
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
                      thumbColor: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.58),
                      trackColor: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.10),
                      buttonForegroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurface,
                      buttonBackgroundColor: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.92),
                      onScrollToOffset: _scrollToOffset,
                      onScrollbarHoverChanged: _onScrollbarHoverChanged,
                      onReturnButtonHoverChanged: _onReturnButtonHoverChanged,
                      onScrollbarActivity: _onScrollbarActivity,
                      onScrollbarDragStart: _onScrollbarDragStart,
                      onScrollbarDragEnd: _onScrollbarDragEnd,
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
