import 'dart:collection';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'ghostty_bindings.g.dart';
import 'terminal_scroll_driver.dart';
import 'terminal_snapshot.dart';
import 'terminal_state.dart';

class TerminalPainter extends CustomPainter {
  final TerminalState state;
  final double cellWidth;
  final double cellHeight;
  final double padding;
  final String fontFamily;
  final List<String> fontFamilyFallback;
  final double fontSize;
  final Color? defaultForeground;
  final Color? defaultBackground;
  final bool showCursor;

  TerminalPainter({
    required this.state,
    required this.cellWidth,
    required this.cellHeight,
    this.padding = 4.0,
    this.fontFamily = 'Menlo',
    this.fontFamilyFallback = const [],
    this.fontSize = 14.0,
    this.defaultForeground,
    this.defaultBackground,
    this.showCursor = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final colors = state.colors;

    // Use sensible defaults when the terminal hasn't configured colors
    final bgColor = defaultBackground ?? _renderBackground(colors);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = bgColor,
    );

    final fgDefault = defaultForeground ?? _renderForeground(colors);

    // Iterate rows
    state.populateRowIterator();
    int rowIdx = 0;

    while (state.rowIteratorNext()) {
      final y = padding + rowIdx * cellHeight;

      state.populateRowCells();
      int colIdx = 0;
      while (state.rowCellsNext()) {
        final wide = state.cellWide;

        // The right half of a wide (CJK) glyph; the lead cell renders it.
        if (wide == GhosttyCellWide.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
          colIdx++;
          continue;
        }

        final x = padding + colIdx * cellWidth;
        final drawWidth = wide == GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE
            ? cellWidth * 2
            : cellWidth;
        final graphemeLen = state.getCellGraphemeLen();

        if (graphemeLen > 0) {
          final style = state.cellStyle;
          final grapheme = state.getCellGrapheme(graphemeLen);

          // Resolve colors
          var fg = _resolveColor(style.fg_color, fgDefault);
          var bg = _resolveColor(style.bg_color, bgColor);

          if (style.inverse) {
            final tmp = fg;
            fg = bg;
            bg = tmp;
          }

          if (style.faint) {
            fg = fg.withValues(alpha: 0.5);
          }

          // Draw background if non-default
          if (bg != bgColor) {
            canvas.drawRect(
              Rect.fromLTWH(x, y, drawWidth, cellHeight),
              Paint()..color = bg,
            );
          }

          // Draw text
          if (!style.invisible && grapheme.isNotEmpty) {
            _drawText(
              canvas,
              grapheme,
              x,
              y,
              fg,
              bold: style.bold,
              italic: style.italic,
            );
          }
        } else {
          // Empty cell — check for bg-only styling
          final style = state.cellStyle;
          var bg = _resolveColor(style.bg_color, bgColor);
          if (style.inverse) {
            bg = _resolveColor(style.fg_color, fgDefault);
          }
          if (bg != bgColor) {
            canvas.drawRect(
              Rect.fromLTWH(x, y, drawWidth, cellHeight),
              Paint()..color = bg,
            );
          }
        }

        colIdx++;
      }

      state.setRowDirty(false);
      rowIdx++;
    }

    // Draw cursor
    if (showCursor && state.cursorVisible && state.cursorInViewport) {
      final cx = padding + state.cursorX * cellWidth;
      final cy = padding + state.cursorY * cellHeight;
      final cursorColor = colors.cursor_has_value
          ? Color.fromARGB(
              255,
              colors.cursor.r,
              colors.cursor.g,
              colors.cursor.b,
            )
          : fgDefault;

      final cursorStyle = state.cursorStyle;
      switch (cursorStyle) {
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
          canvas.drawRect(
            Rect.fromLTWH(cx, cy, cellWidth, cellHeight),
            Paint()..color = cursorColor,
          );
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
          canvas.drawRect(
            Rect.fromLTWH(cx, cy, 2, cellHeight),
            Paint()..color = cursorColor,
          );
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
          canvas.drawRect(
            Rect.fromLTWH(cx, cy + cellHeight - 2, cellWidth, 2),
            Paint()..color = cursorColor,
          );
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
          canvas.drawRect(
            Rect.fromLTWH(cx, cy, cellWidth, cellHeight),
            Paint()..color = cursorColor,
          );
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_MAX_VALUE:
          break;
      }
    }

    // Reset dirty flag
    state.setDirty(GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE);
  }

  Color _resolveColor(GhosttyStyleColor styleColor, Color defaultColor) {
    switch (styleColor.tag) {
      case GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE:
        return defaultColor;
      case GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB:
        final rgb = styleColor.value.rgb;
        return Color.fromARGB(255, rgb.r, rgb.g, rgb.b);
      case GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE:
        final idx = styleColor.value.palette;
        final (r, g, b) = state.paletteColor(idx);
        return Color.fromARGB(255, r, g, b);
      case GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_TAG_MAX_VALUE:
        return defaultColor;
    }
  }

  Color _renderBackground(GhosttyRenderStateColors colors) {
    if (colors.background.r == 0 &&
        colors.background.g == 0 &&
        colors.background.b == 0 &&
        colors.foreground.r == 0 &&
        colors.foreground.g == 0 &&
        colors.foreground.b == 0) {
      return const Color(0xFF1E1E2E);
    }
    return Color.fromARGB(
      255,
      colors.background.r,
      colors.background.g,
      colors.background.b,
    );
  }

  Color _renderForeground(GhosttyRenderStateColors colors) {
    if (colors.foreground.r == 0 &&
        colors.foreground.g == 0 &&
        colors.foreground.b == 0) {
      return const Color(0xFFCDD6F4);
    }
    return Color.fromARGB(
      255,
      colors.foreground.r,
      colors.foreground.g,
      colors.foreground.b,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    double x,
    double y,
    Color color, {
    bool bold = false,
    bool italic = false,
  }) {
    _drawTerminalText(
      canvas,
      text,
      x,
      y,
      color,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: fontSize,
      bold: bold,
      italic: italic,
    );
  }

  @override
  bool shouldRepaint(covariant TerminalPainter oldDelegate) => true;
}

class TerminalSnapshotPainter extends CustomPainter {
  final TerminalSnapshot snapshot;
  final double cellWidth;
  final double cellHeight;
  final double padding;
  final String fontFamily;
  final List<String> fontFamilyFallback;
  final double fontSize;
  final bool showCursor;
  final TerminalSelection? selection;
  final Color selectionBackground;
  final Color selectionForeground;
  final TerminalRenderCache? renderCache;
  final double viewportOffsetRows;
  final TerminalViewportRowCache? scrollRowCache;

  /// IME composition (preedit) text to render inline at the cursor. Null when
  /// no composition is active. This is a client-side overlay only — nothing is
  /// sent to the remote PTY until the composition commits.
  final String? preeditText;

  TerminalSnapshotPainter({
    required this.snapshot,
    required this.cellWidth,
    required this.cellHeight,
    this.padding = 4.0,
    this.fontFamily = 'Menlo',
    this.fontFamilyFallback = const [],
    this.fontSize = 14.0,
    this.showCursor = true,
    this.selection,
    this.selectionBackground = const Color(0x996EA8FE),
    this.selectionForeground = Colors.white,
    this.renderCache,
    this.preeditText,
    double? viewportOffsetRows,
    this.scrollRowCache,
  }) : viewportOffsetRows =
           viewportOffsetRows ?? snapshot.viewportOffset.toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final bgColor = Color(snapshot.backgroundArgb);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = bgColor,
    );

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paintRows = _paintRows().toList(growable: false);
    final cache = renderCache;
    if (selection == null && cache != null) {
      cache.prepare(
        rowCount: paintRows.length,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        padding: padding,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: fontSize,
      );
      for (final paintRow in paintRows) {
        _drawCachedRow(canvas, paintRow, cache);
      }
    } else {
      for (final paintRow in paintRows) {
        _drawCellBackgrounds(canvas, paintRow.row, paintRow.y);
      }

      _drawSelection(canvas, paintRows);

      for (final paintRow in paintRows) {
        _drawTextRuns(canvas, paintRow.row, paintRow.screenRow, paintRow.y);
      }
    }

    if (showCursor &&
        snapshot.cursorVisible &&
        snapshot.cursorInViewport &&
        snapshot.cursorX >= 0 &&
        snapshot.cursorY >= 0) {
      final cursorSpan = snapshot.cursorCellSpan;
      final cx = padding + cursorSpan.col * cellWidth;
      final cursorScreenRow = snapshot.viewportOffset + snapshot.cursorY;
      final cy = padding + (cursorScreenRow - viewportOffsetRows) * cellHeight;
      final cursorWidth = cursorSpan.widthCells * cellWidth;
      final cursorColor = Color(snapshot.cursorArgb);
      switch (GhosttyRenderStateCursorVisualStyle.fromValue(
        snapshot.cursorStyle,
      )) {
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
          canvas.drawRect(
            Rect.fromLTWH(cx, cy, cursorWidth, cellHeight),
            Paint()..color = cursorColor,
          );
          _drawCursorCellText(canvas, cursorColor);
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
          canvas.drawRect(
            Rect.fromLTWH(cx, cy, 2, cellHeight),
            Paint()..color = cursorColor,
          );
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
          canvas.drawRect(
            Rect.fromLTWH(cx, cy + cellHeight - 2, cursorWidth, 2),
            Paint()..color = cursorColor,
          );
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
          final rect = Rect.fromLTWH(
            cx,
            cy,
            cursorWidth,
            cellHeight,
          ).deflate(0.5);
          canvas.drawRect(
            rect,
            Paint()
              ..color = cursorColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        case GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_MAX_VALUE:
          break;
      }
    }

    _drawPreedit(canvas);
    canvas.restore();
  }

  Iterable<_TerminalPaintRow> _paintRows() sync* {
    final range = terminalFractionalViewportRowRange(
      viewportOffset: viewportOffsetRows,
      visibleRows: snapshot.rows,
      totalRows: snapshot.scrollTotalRows,
    );
    for (var screenRow = range.first; screenRow <= range.last; screenRow++) {
      var row = scrollRowCache?.rowAt(screenRow);
      if (row == null) {
        final snapshotIndex = screenRow - snapshot.viewportOffset;
        if (snapshotIndex >= 0 && snapshotIndex < snapshot.lines.length) {
          row = snapshot.lines[snapshotIndex];
        }
      }
      if (row == null) continue;
      yield _TerminalPaintRow(
        screenRow: screenRow,
        row: row,
        y: padding + (screenRow - viewportOffsetRows) * cellHeight,
      );
    }
  }

  void _drawCursorCellText(Canvas canvas, Color cursorColor) {
    final cell = snapshot.cursorCell;
    if (cell == null || cell.invisible || cell.text.isEmpty) return;
    final preferred = Color(cell.backgroundArgb);
    final x = padding + cell.col * cellWidth;
    final cursorScreenRow = snapshot.viewportOffset + snapshot.cursorY;
    final y = padding + (cursorScreenRow - viewportOffsetRows) * cellHeight;
    final widthCells = cell.widthCells <= 0 ? 1 : cell.widthCells;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(x, y, widthCells * cellWidth, cellHeight));
    _drawTerminalText(
      canvas,
      cell.text,
      x,
      y,
      _cursorTextColor(cursorColor, preferred),
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: fontSize,
      bold: cell.bold,
      italic: cell.italic,
    );
    canvas.restore();
  }

  /// Draw the IME composition string on the cursor row. Mirrors ghostty's
  /// renderer: the preedit stays on a single line and, when it runs past the
  /// right edge, shifts left so the active tail stays visible (the oldest
  /// codepoints are clipped off the left). See ghostty `State.zig` Preedit.range.
  void _drawPreedit(Canvas canvas) {
    final text = preeditText;
    if (text == null || text.isEmpty) return;
    if (cellWidth <= 0 || cellHeight <= 0) return;
    if (!snapshot.cursorInViewport ||
        snapshot.cursorX < 0 ||
        snapshot.cursorY < 0) {
      return;
    }

    final cursorScreenRow = snapshot.viewportOffset + snapshot.cursorY;
    final y = padding + (cursorScreenRow - viewportOffsetRows) * cellHeight;
    final startX = padding + snapshot.cursorX * cellWidth;
    // The preedit must never paint left of the cursor — content there is
    // already-committed terminal output. This is the hard left boundary.
    final leftEdge = startX;
    final rightEdge = padding + snapshot.cols * cellWidth;

    final fg = Color(snapshot.foregroundArgb);
    final bg = Color(snapshot.backgroundArgb);

    // Lay out the composing string on a single unwrapped line.
    final paragraph =
        (ui.ParagraphBuilder(
                ui.ParagraphStyle(
                  fontFamily: fontFamily,
                  fontSize: fontSize,
                  strutStyle: ui.StrutStyle(
                    fontFamily: fontFamily,
                    fontSize: fontSize,
                    forceStrutHeight: true,
                  ),
                ),
              )
              ..pushStyle(
                ui.TextStyle(
                  color: fg,
                  fontFamily: fontFamily,
                  fontFamilyFallback: fontFamilyFallback,
                  fontSize: fontSize,
                ),
              )
              ..addText(text))
            .build()
          ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final textWidth = paragraph.longestLine;
    if (textWidth <= 0) return;

    // Anchor at the cursor; shift left if the tail would overflow the right
    // edge. drawX may end up left of leftEdge — the clip below trims it.
    var drawX = startX;
    if (drawX + textWidth > rightEdge) {
      drawX = rightEdge - textWidth;
    }

    final visibleLeft = drawX < leftEdge ? leftEdge : drawX;
    final spanRight = drawX + textWidth;
    final visibleRight = spanRight > rightEdge ? rightEdge : spanRight;
    if (visibleRight <= visibleLeft) return;

    canvas.save();
    // Confine drawing to the cursor row between the terminal margins.
    canvas.clipRect(
      Rect.fromLTWH(leftEdge, y, rightEdge - leftEdge, cellHeight),
    );

    // Mask the underlying grid so the composition is legible.
    canvas.drawRect(
      Rect.fromLTWH(visibleLeft, y, visibleRight - visibleLeft, cellHeight),
      Paint()..color = bg,
    );

    canvas.drawParagraph(paragraph, Offset(drawX, y));

    // Underline the span — the conventional preedit affordance.
    canvas.drawRect(
      Rect.fromLTWH(
        visibleLeft,
        y + cellHeight - 1,
        visibleRight - visibleLeft,
        1,
      ),
      Paint()..color = fg,
    );

    canvas.restore();
  }

  void _drawCellBackgrounds(Canvas canvas, TerminalSnapshotRow row, double y) {
    _CellBackgroundRun? run;

    void flush() {
      final current = run;
      if (current == null) return;
      final x = padding + current.startCol * cellWidth;
      final width = (current.endCol - current.startCol + 1) * cellWidth;
      canvas.drawRect(
        Rect.fromLTWH(x, y, width, cellHeight),
        Paint()..color = Color(current.backgroundArgb),
      );
      run = null;
    }

    for (final cell in row.cells) {
      if (!cell.drawsBackground) {
        flush();
        continue;
      }
      if (run != null && run!.canAppend(cell)) {
        run = run!.append(cell);
        continue;
      }
      flush();
      run = _CellBackgroundRun(
        startCol: cell.col,
        endCol: cell.endCol,
        backgroundArgb: cell.backgroundArgb,
      );
    }
    flush();
  }

  void _drawTextRuns(
    Canvas canvas,
    TerminalSnapshotRow row,
    int screenRow,
    double y,
  ) {
    _CellTextRun? run;

    void flush() {
      final current = run;
      if (current == null) return;
      _drawTerminalText(
        canvas,
        current.text,
        padding + current.startCol * cellWidth,
        y,
        current.foreground,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: fontSize,
        bold: current.bold,
        italic: current.italic,
      );
      run = null;
    }

    for (final cell in row.cells) {
      if (cell.invisible || cell.text.isEmpty) {
        flush();
        continue;
      }

      final selected = selection?.intersectsCell(
        row: screenRow,
        col: cell.col,
        widthCells: cell.widthCells,
        cols: snapshot.cols,
      );
      final foreground = selected == true
          ? selectionForeground
          : Color(cell.foregroundArgb);

      if (!_isAsciiSingleWidthCell(cell)) {
        flush();
        _drawTerminalText(
          canvas,
          cell.text,
          padding + cell.col * cellWidth,
          y,
          foreground,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          fontSize: fontSize,
          bold: cell.bold,
          italic: cell.italic,
        );
        continue;
      }

      if (run != null && run!.canAppend(cell, foreground)) {
        run!.append(cell);
        continue;
      }

      flush();
      run = _CellTextRun(
        startCol: cell.col,
        foreground: foreground,
        bold: cell.bold,
        italic: cell.italic,
      )..append(cell);
    }
    flush();
  }

  void _drawCachedRow(
    Canvas canvas,
    _TerminalPaintRow paintRow,
    TerminalRenderCache cache,
  ) {
    final row = paintRow.row;
    final key = row.renderKey;
    var picture = cache.pictureFor(key);
    if (picture == null) {
      final recorder = ui.PictureRecorder();
      final rowCanvas = Canvas(recorder);
      _drawCellBackgrounds(rowCanvas, row, 0);
      _drawTextRuns(rowCanvas, row, paintRow.screenRow, 0);
      picture = recorder.endRecording();
      cache.put(key, picture);
    }

    canvas
      ..save()
      ..translate(0, paintRow.y)
      ..drawPicture(picture)
      ..restore();
  }

  void _drawSelection(Canvas canvas, List<_TerminalPaintRow> paintRows) {
    final rawRange = selection;
    if (rawRange == null || cellWidth <= 0 || cellHeight <= 0) return;
    final range = snapshot.alignSelectionToCellBoundaries(rawRange);
    final paint = Paint()..color = selectionBackground;
    for (final paintRow in paintRows) {
      final columns = range.columnsForRow(paintRow.screenRow, snapshot.cols);
      if (columns == null || columns.endCol < columns.startCol) continue;
      final x = padding + columns.startCol * cellWidth;
      final width = (columns.endCol - columns.startCol + 1) * cellWidth;
      canvas.drawRect(Rect.fromLTWH(x, paintRow.y, width, cellHeight), paint);
    }
  }

  @override
  bool shouldRepaint(covariant TerminalSnapshotPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot ||
      oldDelegate.cellWidth != cellWidth ||
      oldDelegate.cellHeight != cellHeight ||
      oldDelegate.padding != padding ||
      oldDelegate.fontFamily != fontFamily ||
      oldDelegate.fontSize != fontSize ||
      oldDelegate.showCursor != showCursor ||
      oldDelegate.selection != selection ||
      oldDelegate.selectionBackground != selectionBackground ||
      oldDelegate.selectionForeground != selectionForeground ||
      oldDelegate.renderCache != renderCache ||
      oldDelegate.preeditText != preeditText ||
      oldDelegate.viewportOffsetRows != viewportOffsetRows ||
      oldDelegate.scrollRowCache != scrollRowCache;
}

class _TerminalPaintRow {
  final int screenRow;
  final TerminalSnapshotRow row;
  final double y;

  const _TerminalPaintRow({
    required this.screenRow,
    required this.row,
    required this.y,
  });
}

class TerminalRenderCache {
  final LinkedHashMap<TerminalRowRenderKey, _CachedTerminalRow> _rows =
      LinkedHashMap<TerminalRowRenderKey, _CachedTerminalRow>();
  int? _configSignature;
  int _maxEntries = 256;
  bool _disposed = false;

  void prepare({
    required int rowCount,
    required double cellWidth,
    required double cellHeight,
    required double padding,
    required String fontFamily,
    required List<String> fontFamilyFallback,
    required double fontSize,
  }) {
    if (_disposed) return;
    final nextConfig = Object.hash(
      cellWidth,
      cellHeight,
      padding,
      fontFamily,
      Object.hashAll(fontFamilyFallback),
      fontSize,
    );
    _maxEntries = (rowCount * 8).clamp(128, 1024);
    if (_configSignature != nextConfig) {
      clear();
      _configSignature = nextConfig;
    }
    _evictOverflow();
  }

  ui.Picture? pictureFor(TerminalRowRenderKey key) {
    if (_disposed) return null;
    final cached = _rows.remove(key);
    if (cached == null) return null;
    _rows[key] = cached;
    return cached.picture;
  }

  void put(TerminalRowRenderKey key, ui.Picture picture) {
    if (_disposed) {
      picture.dispose();
      return;
    }
    _rows.remove(key)?.picture.dispose();
    _rows[key] = _CachedTerminalRow(picture);
    _evictOverflow();
  }

  void clear() {
    for (final row in _rows.values) {
      row.picture.dispose();
    }
    _rows.clear();
  }

  void dispose() {
    if (_disposed) return;
    clear();
    _disposed = true;
  }

  void _evictOverflow() {
    while (_rows.length > _maxEntries) {
      final key = _rows.keys.first;
      _rows.remove(key)?.picture.dispose();
    }
  }
}

class _CachedTerminalRow {
  final ui.Picture picture;

  const _CachedTerminalRow(this.picture);
}

bool _isAsciiSingleWidthCell(TerminalSnapshotCell cell) {
  if (cell.widthCells != 1 || cell.text.length != 1) return false;
  final codeUnit = cell.text.codeUnitAt(0);
  return codeUnit >= 0x20 && codeUnit <= 0x7e;
}

class _CellBackgroundRun {
  final int startCol;
  final int endCol;
  final int backgroundArgb;

  const _CellBackgroundRun({
    required this.startCol,
    required this.endCol,
    required this.backgroundArgb,
  });

  bool canAppend(TerminalSnapshotCell cell) {
    return cell.backgroundArgb == backgroundArgb && cell.col == endCol + 1;
  }

  _CellBackgroundRun append(TerminalSnapshotCell cell) {
    return _CellBackgroundRun(
      startCol: startCol,
      endCol: cell.endCol,
      backgroundArgb: backgroundArgb,
    );
  }
}

class _CellTextRun {
  final int startCol;
  final Color foreground;
  final bool bold;
  final bool italic;
  final StringBuffer _text = StringBuffer();
  int _endCol;

  _CellTextRun({
    required this.startCol,
    required this.foreground,
    required this.bold,
    required this.italic,
  }) : _endCol = startCol - 1;

  String get text => _text.toString();

  bool canAppend(TerminalSnapshotCell cell, Color nextForeground) {
    return cell.col == _endCol + 1 &&
        nextForeground == foreground &&
        cell.bold == bold &&
        cell.italic == italic;
  }

  void append(TerminalSnapshotCell cell) {
    _text.write(cell.text);
    _endCol = cell.endCol;
  }
}

void _drawTerminalText(
  Canvas canvas,
  String text,
  double x,
  double y,
  Color color, {
  required String fontFamily,
  required List<String> fontFamilyFallback,
  required double fontSize,
  bool bold = false,
  bool italic = false,
}) {
  // Force the primary (monospace) font's line metrics so fallback-font glyphs
  // (CJK) share the same baseline as ASCII and never exceed cellHeight.
  final builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            strutStyle: ui.StrutStyle(
              fontFamily: fontFamily,
              fontSize: fontSize,
              forceStrutHeight: true,
            ),
          ),
        )
        ..pushStyle(
          ui.TextStyle(
            color: color,
            fontFamily: fontFamily,
            fontFamilyFallback: fontFamilyFallback,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          ),
        )
        ..addText(text);

  // Unbounded width: a single grapheme must never wrap, even if the fallback
  // font's advance slightly exceeds two cells.
  final paragraph = builder.build()
    ..layout(const ui.ParagraphConstraints(width: double.infinity));

  canvas.drawParagraph(paragraph, Offset(x, y));
}

Color _cursorTextColor(Color cursorColor, Color preferred) {
  if (_contrastRatio(cursorColor, preferred) >= 3) return preferred;
  const black = Color(0xff000000);
  const white = Color(0xffffffff);
  return _contrastRatio(cursorColor, black) >=
          _contrastRatio(cursorColor, white)
      ? black
      : white;
}

double _contrastRatio(Color a, Color b) {
  final aLuminance = a.computeLuminance();
  final bLuminance = b.computeLuminance();
  final lighter = aLuminance >= bLuminance ? aLuminance : bLuminance;
  final darker = aLuminance >= bLuminance ? bLuminance : aLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
