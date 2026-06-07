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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/motif_client.dart';
import '../ui/theme/motif_theme.dart';
import 'terminal_error_view.dart';
import 'terminal_focus_policy.dart';
import 'terminal_fonts.dart';
import 'terminal_palette.dart';
import 'web_key_encoder.dart';

@JS('GhosttyVt')
external _GhosttyVt? get _ghosttyVt;

extension type _GhosttyVt(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> get ready;
  external int newTerminal(int cols, int rows);
  external void write(int term, JSUint8Array bytes);
  external String gridText(int term);
  external String gridCellsJson(int term);
}

Widget buildWebTerminal({
  required MotifClient motif,
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
  final MotifClient motif;
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
  int? _term;
  List<List<_Run>> _rows = const [];
  int _curX = -1, _curY = -1;
  bool _failed = false;
  Object? _failure;
  final ScrollController _scroll = ScrollController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'Wasm terminal');
  Timer? _repaint;

  @override
  void initState() {
    super.initState();
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
      setState(() => _rows = _parseGrid(_ghosttyVt!.gridCellsJson(_term!)));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
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
    _scroll.dispose();
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _requestFocus(),
        child: Container(
          color: widget.palette.background,
          padding: const EdgeInsets.all(MotifSpacing.sm),
          child: SelectionArea(
            child: ListView.builder(
              controller: _scroll,
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
