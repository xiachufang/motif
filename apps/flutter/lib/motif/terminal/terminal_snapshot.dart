class TerminalSnapshot {
  final int cols;
  final int rows;
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
  final List<TerminalSnapshotRow> lines;

  const TerminalSnapshot({
    required this.cols,
    required this.rows,
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
    final range = selection.normalized;
    final maxRow = lines.length - 1;
    var startRow = _clampInt(range.base.row, 0, maxRow);
    var endRow = _clampInt(range.extent.row, 0, maxRow);
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
}

class TerminalSnapshotRow {
  final String text;
  final List<TerminalSnapshotCell> cells;

  const TerminalSnapshotRow({required this.text, required this.cells});

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
