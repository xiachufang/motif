class TerminalSnapshot {
  final int cols;
  final int rows;
  final int viewportOffset;
  final int backgroundArgb;
  final int foregroundArgb;
  final int cursorArgb;
  final bool cursorVisible;
  final bool cursorInViewport;
  final int cursorX;
  final int cursorY;
  final int cursorStyle;
  final bool mouseTrackingActive;
  final bool alternateScreenActive;
  final TerminalSelection? selection;
  final List<TerminalSnapshotRow> lines;

  const TerminalSnapshot({
    required this.cols,
    required this.rows,
    this.viewportOffset = 0,
    required this.backgroundArgb,
    required this.foregroundArgb,
    required this.cursorArgb,
    required this.cursorVisible,
    required this.cursorInViewport,
    required this.cursorX,
    required this.cursorY,
    required this.cursorStyle,
    required this.mouseTrackingActive,
    required this.alternateScreenActive,
    this.selection,
    required this.lines,
  });

  String get visibleText {
    final rows = lines.map((line) => line.text.trimRight()).toList();
    while (rows.isNotEmpty && rows.last.isEmpty) {
      rows.removeLast();
    }
    return rows.join('\n');
  }

  String selectedText(TerminalSelection selection) {
    if (lines.isEmpty || cols <= 0) return '';
    final range = visibleSelection(selection);
    if (range == null) return '';
    final maxRow = lines.length - 1;
    var startRow = _clampInt(range.base.row - viewportOffset, 0, maxRow);
    var endRow = _clampInt(range.extent.row - viewportOffset, 0, maxRow);
    if (endRow < startRow) {
      final tmp = startRow;
      startRow = endRow;
      endRow = tmp;
    }

    final rows = <String>[];
    for (var row = startRow; row <= endRow; row++) {
      final startCol = row == startRow
          ? _clampInt(range.base.col, 0, cols - 1)
          : 0;
      final endCol = row == endRow
          ? _clampInt(range.extent.col, 0, cols - 1)
          : cols - 1;
      rows.add(
        lines[row]
            .textForColumns(startCol: startCol, endCol: endCol)
            .trimRight(),
      );
    }
    return rows.join('\n');
  }

  TerminalSelection? wordSelectionAt(TerminalCellPoint point) {
    final viewportRow = point.row - viewportOffset;
    if (viewportRow < 0 || viewportRow >= lines.length || cols <= 0) {
      return null;
    }
    final row = lines[viewportRow];
    final hitIndex = row.cellIndexForColumn(point.col);
    if (hitIndex == null) return null;
    final hit = row.cells[hitIndex];
    if (!_isSelectableWordCell(hit)) return null;

    var startCol = hit.col;
    var endCol = hit.endCol;

    for (var i = hitIndex - 1; i >= 0; i--) {
      final cell = row.cells[i];
      if (!_isSelectableWordCell(cell) || cell.endCol + 1 != startCol) {
        break;
      }
      startCol = cell.col;
    }

    for (var i = hitIndex + 1; i < row.cells.length; i++) {
      final cell = row.cells[i];
      if (!_isSelectableWordCell(cell) || cell.col != endCol + 1) {
        break;
      }
      endCol = cell.endCol;
    }

    return TerminalSelection(
      base: TerminalCellPoint(
        row: viewportOffset + viewportRow,
        col: _clampInt(startCol, 0, cols - 1),
      ),
      extent: TerminalCellPoint(
        row: viewportOffset + viewportRow,
        col: _clampInt(endCol, 0, cols - 1),
      ),
    );
  }

  TerminalSelection? visibleSelection(TerminalSelection selection) {
    if (lines.isEmpty || cols <= 0) return null;
    final range = selection.normalized;
    final firstVisibleRow = viewportOffset;
    final lastVisibleRow = viewportOffset + lines.length - 1;
    if (range.extent.row < firstVisibleRow || range.base.row > lastVisibleRow) {
      return null;
    }

    final startRow = _clampInt(range.base.row, firstVisibleRow, lastVisibleRow);
    final endRow = _clampInt(range.extent.row, firstVisibleRow, lastVisibleRow);
    return alignSelectionToCellBoundaries(
      TerminalSelection(
        base: TerminalCellPoint(
          row: startRow,
          col: startRow == range.base.row ? range.base.col : 0,
        ),
        extent: TerminalCellPoint(
          row: endRow,
          col: endRow == range.extent.row ? range.extent.col : cols - 1,
        ),
      ),
    );
  }

  /// Expand selection endpoints that land on part of a wide cell so the
  /// visual range always covers the complete grapheme.
  TerminalSelection alignSelectionToCellBoundaries(
    TerminalSelection selection,
  ) {
    final range = selection.normalized;
    return TerminalSelection(
      base: _alignSelectionPoint(range.base, leadingEdge: true),
      extent: _alignSelectionPoint(range.extent, leadingEdge: false),
    );
  }

  /// The grid span occupied by the grapheme under the cursor.
  ///
  /// Ghostty may position the cursor on the spacer tail of a wide character.
  /// In that case the visual cursor starts at the lead cell and spans both
  /// columns.
  ({int col, int widthCells}) get cursorCellSpan {
    final cell = cursorCell;
    if (cell == null) return (col: cursorX, widthCells: 1);
    final widthCells = cell.widthCells <= 0 ? 1 : cell.widthCells;
    return (col: cell.col, widthCells: widthCells);
  }

  /// The rendered cell under the cursor, including the lead cell when the
  /// cursor is positioned on a wide character's spacer tail.
  TerminalSnapshotCell? get cursorCell {
    if (!cursorInViewport || cursorY < 0 || cursorY >= lines.length) {
      return null;
    }
    final row = lines[cursorY];
    final cellIndex = row.cellIndexForColumn(cursorX);
    return cellIndex == null ? null : row.cells[cellIndex];
  }

  TerminalCellPoint _alignSelectionPoint(
    TerminalCellPoint point, {
    required bool leadingEdge,
  }) {
    final viewportRow = point.row - viewportOffset;
    if (viewportRow < 0 || viewportRow >= lines.length) return point;
    final row = lines[viewportRow];
    final cellIndex = row.cellIndexForColumn(point.col);
    if (cellIndex == null) return point;
    final cell = row.cells[cellIndex];
    return TerminalCellPoint(
      row: point.row,
      col: leadingEdge ? cell.col : cell.endCol,
    );
  }
}

class TerminalSnapshotRow {
  final String text;
  final List<TerminalSnapshotCell> cells;

  const TerminalSnapshotRow({required this.text, required this.cells});

  int? cellIndexForColumn(int col) {
    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      if (col >= cell.col && col <= cell.endCol) return i;
      if (cell.col > col) break;
    }
    return null;
  }

  String textForColumns({required int startCol, required int endCol}) {
    if (endCol < startCol) return '';
    final out = StringBuffer();
    var cursor = startCol;
    for (final cell in cells) {
      final widthCells = cell.widthCells <= 0 ? 1 : cell.widthCells;
      final cellStart = cell.col;
      final cellEnd = cell.col + widthCells - 1;
      if (cellEnd < startCol) continue;
      if (cellStart > endCol) break;
      if (cellStart > cursor) {
        out.write(' ' * (cellStart - cursor));
      }
      if (!cell.invisible && cell.text.isNotEmpty) {
        out.write(cell.text);
      }
      if (cellEnd + 1 > cursor) {
        cursor = cellEnd + 1;
      }
    }
    return out.toString();
  }
}

class TerminalSnapshotCell {
  final int col;
  final int widthCells;
  final String text;
  final int foregroundArgb;
  final int backgroundArgb;
  final bool drawsBackground;
  final bool bold;
  final bool italic;
  final bool invisible;

  const TerminalSnapshotCell({
    required this.col,
    required this.widthCells,
    required this.text,
    required this.foregroundArgb,
    required this.backgroundArgb,
    required this.drawsBackground,
    required this.bold,
    required this.italic,
    required this.invisible,
  });

  int get endCol => col + (widthCells <= 0 ? 1 : widthCells) - 1;
}

bool _isSelectableWordCell(TerminalSnapshotCell cell) {
  return !cell.invisible && cell.text.trim().isNotEmpty;
}

class TerminalCellPoint implements Comparable<TerminalCellPoint> {
  final int row;
  final int col;

  const TerminalCellPoint({required this.row, required this.col});

  @override
  int compareTo(TerminalCellPoint other) {
    final rowCompare = row.compareTo(other.row);
    if (rowCompare != 0) return rowCompare;
    return col.compareTo(other.col);
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalCellPoint && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);
}

class TerminalSelection {
  final TerminalCellPoint base;
  final TerminalCellPoint extent;

  const TerminalSelection({required this.base, required this.extent});

  TerminalSelection get normalized {
    if (base.compareTo(extent) <= 0) return this;
    return TerminalSelection(base: extent, extent: base);
  }

  ({int startCol, int endCol})? columnsForRow(int row, int cols) {
    if (cols <= 0) return null;
    final range = normalized;
    if (row < range.base.row || row > range.extent.row) return null;
    final startCol = row == range.base.row ? range.base.col : 0;
    final endCol = row == range.extent.row ? range.extent.col : cols - 1;
    return (
      startCol: _clampInt(startCol, 0, cols - 1),
      endCol: _clampInt(endCol, 0, cols - 1),
    );
  }

  bool intersectsCell({
    required int row,
    required int col,
    required int widthCells,
    required int cols,
  }) {
    final range = columnsForRow(row, cols);
    if (range == null) return false;
    final cellEnd = col + (widthCells <= 0 ? 1 : widthCells) - 1;
    return cellEnd >= range.startCol && col <= range.endCol;
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalSelection &&
      other.base == base &&
      other.extent == extent;

  @override
  int get hashCode => Object.hash(base, extent);
}

int _clampInt(int value, int min, int max) {
  if (max < min) return min;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}
