import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/ghostty_bindings.g.dart';
import 'package:motif/motif/terminal/terminal_painter.dart';
import 'package:motif/motif/terminal/terminal_scroll_driver.dart';
import 'package:motif/motif/terminal/terminal_snapshot.dart';

void main() {
  test('block cursor redraws its character with a contrasting color', () async {
    final snapshot = TerminalSnapshot(
      cols: 2,
      rows: 1,
      backgroundArgb: 0xff000000,
      foregroundArgb: 0xffffffff,
      cursorArgb: 0xff000000,
      cursorVisible: true,
      cursorInViewport: true,
      cursorX: 0,
      cursorY: 0,
      cursorStyle: GhosttyRenderStateCursorVisualStyle
          .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
          .value,
      mouseTrackingActive: false,
      alternateScreenActive: false,
      lines: [
        TerminalSnapshotRow(
          cells: const [
            TerminalSnapshotCell(
              col: 0,
              widthCells: 1,
              text: 'M',
              foregroundArgb: 0xffffffff,
              backgroundArgb: 0xff000000,
              drawsBackground: false,
              bold: false,
              italic: false,
              invisible: false,
            ),
          ],
        ),
      ],
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    TerminalSnapshotPainter(
      snapshot: snapshot,
      cellWidth: 14,
      cellHeight: 20,
      padding: 0,
      fontSize: 14,
      showCursor: true,
    ).paint(canvas, const Size(28, 20));

    final image = await recorder.endRecording().toImage(28, 20);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    expect(data, isNotNull);

    var contrastingPixels = 0;
    final bytes = data!.buffer.asUint8List();
    for (var y = 0; y < 20; y++) {
      for (var x = 0; x < 14; x++) {
        final offset = (y * 28 + x) * 4;
        if (bytes[offset] != 0 ||
            bytes[offset + 1] != 0 ||
            bytes[offset + 2] != 0) {
          contrastingPixels++;
        }
      }
    }
    expect(contrastingPixels, greaterThan(0));
  });

  test('Picture cache hit does not decode an encoded row', () {
    const metadata = TerminalFrameMetadata(
      cols: 2,
      rows: 1,
      viewportOffset: 0,
      scrollTotalRows: 1,
      scrollViewportRows: 1,
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
    final encoder = TerminalFrameEncoder(
      frameId: 1,
      baseFrameId: 0,
      full: true,
      metadata: metadata,
    );
    encoder.startRow(0)
      ..addCell(
        col: 0,
        widthCells: 1,
        textBytes: const [0x4d],
        foregroundArgb: 0xffffffff,
        backgroundArgb: 0xff000000,
        drawsBackground: false,
        bold: false,
        italic: false,
        invisible: false,
      )
      ..finish();
    final snapshot = TerminalFrameUpdate.decode(
      encoder.finish(0).bytes,
    ).applyTo(null);
    final row = snapshot.lines.single;
    expect(row.cellsDecoded, isFalse);

    final cache = TerminalRenderCache();
    addTearDown(cache.dispose);
    cache.prepare(
      rowCount: 1,
      cellWidth: 14,
      cellHeight: 20,
      padding: 0,
      fontFamily: 'Menlo',
      fontFamilyFallback: const [],
      fontSize: 14,
    );
    final cachedRecorder = ui.PictureRecorder();
    Canvas(cachedRecorder);
    cache.put(row.renderKey, cachedRecorder.endRecording());

    final recorder = ui.PictureRecorder();
    TerminalSnapshotPainter(
      snapshot: snapshot,
      cellWidth: 14,
      cellHeight: 20,
      padding: 0,
      fontSize: 14,
      showCursor: false,
      renderCache: cache,
    ).paint(Canvas(recorder), const Size(28, 20));
    recorder.endRecording().dispose();

    expect(row.cellsDecoded, isFalse);
  });

  test(
    'fractional viewport paints real rows across both clipped edges',
    () async {
      final first = _colorSnapshot(
        viewportOffset: 0,
        rows: [_colorRow(0xffff0000), _colorRow(0xff00ff00)],
      );
      final adjacent = _colorSnapshot(
        viewportOffset: 1,
        rows: [_colorRow(0xff00ff00), _colorRow(0xff0000ff)],
        scrollTotalRows: 4,
      );
      final bottomOverscan = _colorSnapshot(
        viewportOffset: 2,
        rows: [_colorRow(0xff0000ff), _colorRow(0xffffff00)],
        scrollTotalRows: 4,
      );
      final rowCache = TerminalViewportRowCache()
        ..ingest(first)
        ..ingest(adjacent)
        ..ingest(bottomOverscan);

      final recorder = ui.PictureRecorder();
      TerminalSnapshotPainter(
        snapshot: adjacent,
        cellWidth: 10,
        cellHeight: 10,
        padding: 0,
        fontSize: 8,
        showCursor: false,
        viewportOffsetRows: 0.5,
        scrollRowCache: rowCache,
      ).paint(Canvas(recorder), const Size(10, 30));

      final image = await recorder.endRecording().toImage(10, 30);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      final bytes = data!.buffer.asUint8List();

      expect(_pixelRgb(bytes, width: 10, x: 5, y: 2), (255, 0, 0));
      expect(_pixelRgb(bytes, width: 10, x: 5, y: 7), (0, 255, 0));
      expect(_pixelRgb(bytes, width: 10, x: 5, y: 17), (0, 0, 255));
      expect(_pixelRgb(bytes, width: 10, x: 5, y: 27), (255, 255, 0));
    },
  );

  test('fractional viewport moves immediately before edge prefetch', () async {
    final snapshot = _colorSnapshot(
      viewportOffset: 0,
      rows: [_colorRow(0xffff0000), _colorRow(0xff00ff00)],
    );
    final recorder = ui.PictureRecorder();
    TerminalSnapshotPainter(
      snapshot: snapshot,
      cellWidth: 10,
      cellHeight: 10,
      padding: 0,
      fontSize: 8,
      showCursor: false,
      viewportOffsetRows: 0.5,
    ).paint(Canvas(recorder), const Size(10, 20));

    final image = await recorder.endRecording().toImage(10, 20);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final bytes = data!.buffer.asUint8List();

    expect(_pixelRgb(bytes, width: 10, x: 5, y: 2), (255, 0, 0));
    expect(_pixelRgb(bytes, width: 10, x: 5, y: 7), (0, 255, 0));
    expect(_pixelRgb(bytes, width: 10, x: 5, y: 17), (0, 0, 0));
  });
}

TerminalSnapshot _colorSnapshot({
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

TerminalSnapshotRow _colorRow(int backgroundArgb) {
  return TerminalSnapshotRow(
    cells: [
      TerminalSnapshotCell(
        col: 0,
        widthCells: 1,
        text: '',
        foregroundArgb: 0xffffffff,
        backgroundArgb: backgroundArgb,
        drawsBackground: true,
        bold: false,
        italic: false,
        invisible: false,
      ),
    ],
  );
}

(int, int, int) _pixelRgb(
  List<int> bytes, {
  required int width,
  required int x,
  required int y,
}) {
  final offset = (y * width + x) * 4;
  return (bytes[offset], bytes[offset + 1], bytes[offset + 2]);
}
