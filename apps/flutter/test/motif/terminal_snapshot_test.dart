import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_snapshot.dart';

void main() {
  test('selectedText extracts a trimmed multi-row terminal range', () {
    final snapshot = _snapshot([
      _row([_cell(2, 'a'), _cell(3, 'b'), _cell(5, 'c')]),
      _row([_cell(0, 'd'), _cell(3, 'e')]),
    ], cols: 8);

    final selection = TerminalSelection(
      base: const TerminalCellPoint(row: 0, col: 1),
      extent: const TerminalCellPoint(row: 1, col: 3),
    );

    expect(snapshot.selectedText(selection), ' ab c\nd  e');
  });

  test('selectedText handles reverse drag direction', () {
    final snapshot = _snapshot([
      _row([_cell(1, 'a'), _cell(2, 'b'), _cell(3, 'c')]),
    ], cols: 6);

    final selection = TerminalSelection(
      base: const TerminalCellPoint(row: 0, col: 3),
      extent: const TerminalCellPoint(row: 0, col: 1),
    );

    expect(snapshot.selectedText(selection), 'abc');
  });

  test('selectedText includes wide cells when selecting either half', () {
    final snapshot = _snapshot([
      _row([_cell(1, '好', widthCells: 2)]),
    ], cols: 4);

    final selection = TerminalSelection(
      base: const TerminalCellPoint(row: 0, col: 2),
      extent: const TerminalCellPoint(row: 0, col: 2),
    );

    expect(snapshot.selectedText(selection), '好');
  });

  test('selectedText skips invisible cells while preserving later columns', () {
    final snapshot = _snapshot([
      _row([_cell(0, 'x', invisible: true), _cell(2, 'y')]),
    ], cols: 4);

    final selection = TerminalSelection(
      base: const TerminalCellPoint(row: 0, col: 0),
      extent: const TerminalCellPoint(row: 0, col: 2),
    );

    expect(snapshot.selectedText(selection), ' y');
  });

  test('wordSelectionAt selects the token under the cell', () {
    final snapshot = _snapshot([_row(_cellsFromText('echo hello'))], cols: 16);

    final selection = snapshot.wordSelectionAt(
      const TerminalCellPoint(row: 0, col: 6),
    );

    expect(
      selection,
      const TerminalSelection(
        base: TerminalCellPoint(row: 0, col: 5),
        extent: TerminalCellPoint(row: 0, col: 9),
      ),
    );
    expect(snapshot.selectedText(selection!), 'hello');
  });

  test('wordSelectionAt ignores whitespace cells', () {
    final snapshot = _snapshot([_row(_cellsFromText('echo hello'))], cols: 16);

    expect(
      snapshot.wordSelectionAt(const TerminalCellPoint(row: 0, col: 4)),
      isNull,
    );
  });

  test('wordSelectionAt treats paths and command fragments as one token', () {
    final snapshot = _snapshot([
      _row(_cellsFromText('/usr/bin/env VAR=value')),
    ], cols: 32);

    expect(
      snapshot.wordSelectionAt(const TerminalCellPoint(row: 0, col: 7)),
      const TerminalSelection(
        base: TerminalCellPoint(row: 0, col: 0),
        extent: TerminalCellPoint(row: 0, col: 11),
      ),
    );
    expect(
      snapshot.wordSelectionAt(const TerminalCellPoint(row: 0, col: 16)),
      const TerminalSelection(
        base: TerminalCellPoint(row: 0, col: 13),
        extent: TerminalCellPoint(row: 0, col: 21),
      ),
    );
  });

  test('wordSelectionAt includes wide cells from either half', () {
    final snapshot = _snapshot([
      _row([_cell(1, '好', widthCells: 2)]),
    ], cols: 4);

    const expected = TerminalSelection(
      base: TerminalCellPoint(row: 0, col: 1),
      extent: TerminalCellPoint(row: 0, col: 2),
    );

    expect(
      snapshot.wordSelectionAt(const TerminalCellPoint(row: 0, col: 1)),
      expected,
    );
    expect(
      snapshot.wordSelectionAt(const TerminalCellPoint(row: 0, col: 2)),
      expected,
    );
    expect(snapshot.selectedText(expected), '好');
  });
}

TerminalSnapshot _snapshot(
  List<TerminalSnapshotRow> rows, {
  required int cols,
}) {
  return TerminalSnapshot(
    cols: cols,
    rows: rows.length,
    backgroundArgb: 0xff000000,
    foregroundArgb: 0xffffffff,
    cursorArgb: 0xffffffff,
    cursorVisible: false,
    cursorInViewport: false,
    cursorX: -1,
    cursorY: -1,
    cursorStyle: 0,
    mouseTrackingActive: false,
    alternateScreenActive: false,
    lines: rows,
  );
}

TerminalSnapshotRow _row(List<TerminalSnapshotCell> cells) {
  return TerminalSnapshotRow(
    text: cells.map((cell) => cell.text).join(),
    cells: cells,
  );
}

List<TerminalSnapshotCell> _cellsFromText(String text) {
  return [for (var i = 0; i < text.length; i++) _cell(i, text[i])];
}

TerminalSnapshotCell _cell(
  int col,
  String text, {
  int widthCells = 1,
  bool invisible = false,
}) {
  return TerminalSnapshotCell(
    col: col,
    widthCells: widthCells,
    text: text,
    foregroundArgb: 0xffffffff,
    backgroundArgb: 0xff000000,
    drawsBackground: false,
    bold: false,
    italic: false,
    invisible: invisible,
  );
}
