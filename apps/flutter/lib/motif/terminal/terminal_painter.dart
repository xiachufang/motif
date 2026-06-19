import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'ghostty_bindings.g.dart';
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
    this.preeditText,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgColor = Color(snapshot.backgroundArgb);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = bgColor,
    );

    for (var rowIdx = 0; rowIdx < snapshot.lines.length; rowIdx++) {
      final y = padding + rowIdx * cellHeight;
      for (final cell in snapshot.lines[rowIdx].cells) {
        final x = padding + cell.col * cellWidth;
        final drawWidth = cell.widthCells <= 1
            ? cellWidth
            : cellWidth * cell.widthCells;
        if (cell.drawsBackground) {
          canvas.drawRect(
            Rect.fromLTWH(x, y, drawWidth, cellHeight),
            Paint()..color = Color(cell.backgroundArgb),
          );
        }
      }
    }

    _drawSelection(canvas);

    for (var rowIdx = 0; rowIdx < snapshot.lines.length; rowIdx++) {
      final y = padding + rowIdx * cellHeight;
      for (final cell in snapshot.lines[rowIdx].cells) {
        final x = padding + cell.col * cellWidth;
        if (!cell.invisible && cell.text.isNotEmpty) {
          final selected = selection?.intersectsCell(
            row: rowIdx,
            col: cell.col,
            widthCells: cell.widthCells,
            cols: snapshot.cols,
          );
          _drawTerminalText(
            canvas,
            cell.text,
            x,
            y,
            selected == true ? selectionForeground : Color(cell.foregroundArgb),
            fontFamily: fontFamily,
            fontFamilyFallback: fontFamilyFallback,
            fontSize: fontSize,
            bold: cell.bold,
            italic: cell.italic,
          );
        }
      }
    }

    if (showCursor &&
        snapshot.cursorVisible &&
        snapshot.cursorInViewport &&
        snapshot.cursorX >= 0 &&
        snapshot.cursorY >= 0) {
      final cx = padding + snapshot.cursorX * cellWidth;
      final cy = padding + snapshot.cursorY * cellHeight;
      final cursorColor = Color(snapshot.cursorArgb);
      switch (GhosttyRenderStateCursorVisualStyle.fromValue(
        snapshot.cursorStyle,
      )) {
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

    _drawPreedit(canvas);
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

    final y = padding + snapshot.cursorY * cellHeight;
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

  void _drawSelection(Canvas canvas) {
    final range = selection;
    if (range == null || cellWidth <= 0 || cellHeight <= 0) return;
    final paint = Paint()..color = selectionBackground;
    for (var row = 0; row < snapshot.lines.length; row++) {
      final columns = range.columnsForRow(row, snapshot.cols);
      if (columns == null || columns.endCol < columns.startCol) continue;
      final x = padding + columns.startCol * cellWidth;
      final y = padding + row * cellHeight;
      final width = (columns.endCol - columns.startCol + 1) * cellWidth;
      canvas.drawRect(Rect.fromLTWH(x, y, width, cellHeight), paint);
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
      oldDelegate.preeditText != preeditText;
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
