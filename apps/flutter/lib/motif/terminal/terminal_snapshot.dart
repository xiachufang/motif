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
}

class TerminalSnapshotRow {
  final String text;
  final List<TerminalSnapshotCell> cells;

  const TerminalSnapshotRow({required this.text, required this.cells});
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
