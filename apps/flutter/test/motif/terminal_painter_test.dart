import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/ghostty_bindings.g.dart';
import 'package:motif/motif/terminal/terminal_painter.dart';
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
}
