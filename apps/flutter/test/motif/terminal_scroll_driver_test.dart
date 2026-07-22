import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_scroll_driver.dart';
import 'package:motif/motif/terminal/terminal_snapshot.dart';

void main() {
  test('accumulates logical pixels into terminal rows', () {
    final scroll = TerminalScrollAccumulator();

    expect(scroll.applyPixelDelta(9, 20), 0);
    expect(scroll.applyPixelDelta(11, 20), 1);
    expect(scroll.applyPixelDelta(45, 20), 2);
    expect(scroll.applyPixelDelta(-10, 20), 0);
    expect(scroll.applyPixelDelta(-30, 20), -1);

    scroll.reset();
    expect(scroll.applyPixelDelta(-20, 20), -1);
  });

  test('maps direct touch drag direction to terminal scroll pixels', () {
    expect(touchMoveDeltaToScrollPixels(24), -24);
    expect(touchMoveDeltaToScrollPixels(-18), 18);
    expect(touchMoveDeltaToScrollPixels(0), 0);
  });

  test('reversed scroll position uses zero for the live bottom', () {
    expect(
      terminalScrollPixelsFromViewportOffset(
        viewportOffset: 30,
        maxOffset: 30,
        rowHeight: 20,
      ),
      0,
    );
    expect(
      terminalScrollPixelsFromViewportOffset(
        viewportOffset: 0,
        maxOffset: 30,
        rowHeight: 20,
      ),
      600,
    );
    expect(
      terminalViewportOffsetFromScrollPixels(
        scrollPixels: 0,
        maxOffset: 30,
        rowHeight: 20,
      ),
      30,
    );
    expect(
      terminalViewportOffsetFromScrollPixels(
        scrollPixels: 600,
        maxOffset: 30,
        rowHeight: 20,
      ),
      0,
    );
  });

  test(
    'keeps a fractional viewport while requesting adjacent integer rows',
    () {
      final scroll = TerminalSmoothScrollPosition()
        ..synchronize(viewportOffset: 10, maxOffset: 30);

      final upward = scroll.applyPixelDelta(-10, 20);
      expect(upward.viewportOffset, 9.5);
      expect(upward.requestedOffset, 9);
      expect(upward.rowDelta, -1);

      final reverse = scroll.applyPixelDelta(5, 20);
      expect(reverse.viewportOffset, 9.75);
      expect(reverse.requestedOffset, 10);
      expect(reverse.rowDelta, 1);

      final boundary = scroll.applyPixelDelta(-1000, 20);
      expect(boundary.viewportOffset, 0);
      expect(boundary.requestedOffset, 0);
      expect(boundary.rowDelta, -10);
    },
  );

  test('detects when a half-row viewport has both clipped edges cached', () {
    final cache = TerminalViewportRowCache();
    final first = _snapshot(viewportOffset: 0, rows: [_row('A'), _row('B')]);
    cache.ingest(first);

    expect(cache.covers(0.5, first.rows), isFalse);

    final adjacent = _snapshot(viewportOffset: 1, rows: [_row('B'), _row('C')]);
    cache.ingest(adjacent);
    expect(cache.covers(0.5, adjacent.rows), isTrue);
  });

  test('prefetches a missing bottom row from the adjacent viewport', () {
    final cache = TerminalViewportRowCache()
      ..ingest(
        _snapshot(
          viewportOffset: 10,
          scrollTotalRows: 100,
          rows: [_row('A'), _row('B'), _row('C')],
        ),
      );

    expect(
      cache.prefetchOffset(viewportOffset: 10.5, visibleRows: 3, maxOffset: 97),
      11,
    );

    cache.ingest(
      _snapshot(
        viewportOffset: 11,
        scrollTotalRows: 100,
        rows: [_row('B'), _row('C'), _row('D')],
      ),
    );
    expect(
      cache.prefetchOffset(viewportOffset: 10.5, visibleRows: 3, maxOffset: 97),
      12,
    );
  });

  test(
    'fractional row range floors the top and overscans through bottom ceil',
    () {
      expect(
        terminalFractionalViewportRowRange(
          viewportOffset: 10.5,
          visibleRows: 3,
          totalRows: 100,
        ),
        (first: 10, last: 14),
      );
    },
  );
}

TerminalSnapshot _snapshot({
  required int viewportOffset,
  required List<TerminalSnapshotRow> rows,
  int scrollTotalRows = 3,
}) {
  return TerminalSnapshot(
    cols: 1,
    rows: rows.length,
    viewportOffset: viewportOffset,
    scrollTotalRows: scrollTotalRows,
    scrollViewportRows: rows.length,
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

TerminalSnapshotRow _row(String text) {
  return TerminalSnapshotRow(
    cells: [
      TerminalSnapshotCell(
        col: 0,
        widthCells: 1,
        text: text,
        foregroundArgb: 0xffffffff,
        backgroundArgb: 0xff000000,
        drawsBackground: false,
        bold: false,
        italic: false,
        invisible: false,
      ),
    ],
  );
}
