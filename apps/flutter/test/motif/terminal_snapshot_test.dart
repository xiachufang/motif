import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_snapshot.dart';

void main() {
  test('isAtLatest compares the viewport with the live bottom', () {
    final history = _snapshot(
      [_row(const [])],
      cols: 8,
      viewportOffset: 3,
      scrollTotalRows: 12,
      scrollViewportRows: 3,
    );
    final latest = _snapshot(
      [_row(const [])],
      cols: 8,
      viewportOffset: 9,
      scrollTotalRows: 12,
      scrollViewportRows: 3,
    );

    expect(history.isAtLatest, isFalse);
    expect(latest.isAtLatest, isTrue);
  });

  test('a terminal without scrollback is already at latest', () {
    final snapshot = _snapshot([_row(const [])], cols: 8);

    expect(snapshot.hasScrollback, isFalse);
    expect(snapshot.isAtLatest, isTrue);
  });

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

  test('selection endpoints expand to complete wide cells', () {
    final snapshot = _snapshot([
      _row([
        _cell(0, 'a'),
        _cell(1, '你', widthCells: 2),
        _cell(3, '好', widthCells: 2),
      ]),
    ], cols: 6);

    expect(
      snapshot.alignSelectionToCellBoundaries(
        const TerminalSelection(
          base: TerminalCellPoint(row: 0, col: 2),
          extent: TerminalCellPoint(row: 0, col: 3),
        ),
      ),
      const TerminalSelection(
        base: TerminalCellPoint(row: 0, col: 1),
        extent: TerminalCellPoint(row: 0, col: 4),
      ),
    );
  });

  test('cursor span covers a wide cell from either half', () {
    for (final cursorX in [1, 2]) {
      final snapshot = _snapshot(
        [
          _row([_cell(1, '好', widthCells: 2)]),
        ],
        cols: 4,
        cursorX: cursorX,
      );

      expect(snapshot.cursorCellSpan, (col: 1, widthCells: 2));
    }
  });

  test('cursor span remains one cell on regular or empty cells', () {
    final regular = _snapshot(
      [
        _row([_cell(1, 'a')]),
      ],
      cols: 4,
      cursorX: 1,
    );
    final empty = _snapshot([_row(const [])], cols: 4, cursorX: 2);

    expect(regular.cursorCellSpan, (col: 1, widthCells: 1));
    expect(empty.cursorCellSpan, (col: 2, widthCells: 1));
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

  test('binary rows decode lazily and preserve visible text columns', () {
    final encoder = TerminalFrameEncoder(
      frameId: 1,
      baseFrameId: 0,
      full: true,
      metadata: _metadata(cols: 4, rows: 2),
    );
    encoder.startRow(0)
      ..addCell(
        col: 2,
        widthCells: 1,
        textBytes: const [0x61],
        foregroundArgb: 0xffffffff,
        backgroundArgb: 0xff000000,
        drawsBackground: false,
        bold: false,
        italic: false,
        invisible: false,
      )
      ..finish();
    encoder.startRow(1).finish();

    final snapshot = TerminalFrameUpdate.decode(
      encoder.finish(0).bytes,
    ).applyTo(null);
    expect(snapshot.lines.every((row) => !row.cellsDecoded), isTrue);
    expect(snapshot.lines.first.cells.single.text, 'a');
    expect(snapshot.lines.first.cellsDecoded, isTrue);
    expect(snapshot.lines.last.cellsDecoded, isFalse);
    expect(snapshot.visibleText, '  a');
  });

  test('delta frame reuses unchanged row objects', () {
    final fullEncoder = TerminalFrameEncoder(
      frameId: 1,
      baseFrameId: 0,
      full: true,
      metadata: _metadata(cols: 4, rows: 2),
    );
    fullEncoder.startRow(0).finish();
    fullEncoder.startRow(1).finish();
    final first = TerminalFrameUpdate.decode(
      fullEncoder.finish(0).bytes,
    ).applyTo(null);

    final deltaEncoder = TerminalFrameEncoder(
      frameId: 2,
      baseFrameId: 1,
      full: false,
      metadata: _metadata(cols: 4, rows: 2),
    );
    deltaEncoder.startRow(1)
      ..addCell(
        col: 0,
        widthCells: 1,
        textBytes: const [0x62],
        foregroundArgb: 0xffffffff,
        backgroundArgb: 0xff000000,
        drawsBackground: false,
        bold: false,
        italic: false,
        invisible: false,
      )
      ..finish();
    final second = TerminalFrameUpdate.decode(
      deltaEncoder.finish(0).bytes,
    ).applyTo(first);

    expect(identical(second.lines[0], first.lines[0]), isTrue);
    expect(identical(second.lines[1], first.lines[1]), isFalse);
    expect(second.lines[1].cells.single.text, 'b');
  });
}

TerminalFrameMetadata _metadata({required int cols, required int rows}) {
  return TerminalFrameMetadata(
    cols: cols,
    rows: rows,
    viewportOffset: 0,
    scrollTotalRows: rows,
    scrollViewportRows: rows,
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
  );
}

TerminalSnapshot _snapshot(
  List<TerminalSnapshotRow> rows, {
  required int cols,
  int? cursorX,
  int viewportOffset = 0,
  int scrollTotalRows = 0,
  int scrollViewportRows = 0,
}) {
  return TerminalSnapshot(
    cols: cols,
    rows: rows.length,
    viewportOffset: viewportOffset,
    scrollTotalRows: scrollTotalRows,
    scrollViewportRows: scrollViewportRows,
    backgroundArgb: 0xff000000,
    foregroundArgb: 0xffffffff,
    cursorArgb: 0xffffffff,
    cursorVisible: cursorX != null,
    cursorInViewport: cursorX != null,
    cursorX: cursorX ?? -1,
    cursorY: cursorX == null ? -1 : 0,
    cursorStyle: 0,
    mouseTrackingActive: false,
    alternateScreenActive: false,
    lines: rows,
  );
}

TerminalSnapshotRow _row(List<TerminalSnapshotCell> cells) {
  return TerminalSnapshotRow(cells: cells);
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
