import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_scroll_driver.dart';

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

  test('discrete mouse wheel uses Ghostty whole-row multiplier', () {
    expect(terminalRowsFromDiscreteWheel(-1), -3);
    expect(terminalRowsFromDiscreteWheel(1), 3);
    expect(terminalRowsFromDiscreteWheel(-120), -3);
    expect(terminalRowsFromDiscreteWheel(0), 0);
  });

  test('Flutter and Ghostty use the same forward row axis', () {
    expect(
      terminalScrollPixelsFromViewportOffset(viewportOffset: 0, rowHeight: 20),
      0,
    );
    expect(
      terminalScrollPixelsFromViewportOffset(viewportOffset: 30, rowHeight: 20),
      600,
    );
    expect(
      terminalViewportOffsetFromScrollPixels(
        scrollPixels: 209,
        maxOffset: 30,
        rowHeight: 20,
      ),
      10,
    );
    expect(
      terminalViewportOffsetFromScrollPixels(
        scrollPixels: 211,
        maxOffset: 30,
        rowHeight: 20,
      ),
      10,
    );
    expect(
      terminalViewportPositionFromScrollPixels(
        scrollPixels: 211,
        maxOffset: 30,
        rowHeight: 20,
      ),
      (viewportOffset: 10, pixelRemainder: 11),
    );
    expect(
      terminalViewportPositionFromScrollPixels(
        scrollPixels: 600,
        maxOffset: 30,
        rowHeight: 20,
      ),
      (viewportOffset: 30, pixelRemainder: 0),
    );
  });

  test('history keeps its absolute row while output grows', () {
    const physics = TerminalScrollAnchorPhysics();

    expect(
      physics.adjustPositionForNewDimensions(
        oldPosition: _metrics(pixels: 120, maxScrollExtent: 400),
        newPosition: _metrics(pixels: 120, maxScrollExtent: 460),
        isScrolling: true,
        velocity: 800,
      ),
      120,
    );
  });

  test('history preserves a concurrent drag tick while output grows', () {
    const physics = TerminalScrollAnchorPhysics();

    expect(
      physics.adjustPositionForNewDimensions(
        oldPosition: _metrics(pixels: 120, maxScrollExtent: 400),
        newPosition: _metrics(pixels: 135, maxScrollExtent: 460),
        isScrolling: true,
        velocity: 0,
      ),
      135,
    );
  });

  test('active area follows a growing maximum extent', () {
    const physics = TerminalScrollAnchorPhysics();

    expect(
      physics.adjustPositionForNewDimensions(
        oldPosition: _metrics(pixels: 400, maxScrollExtent: 400),
        newPosition: _metrics(pixels: 400, maxScrollExtent: 460),
        isScrolling: true,
        velocity: 0,
      ),
      460,
    );
  });

  test(
    'Ghostty history state wins even when its offset equals the maximum',
    () {
      const physics = TerminalScrollAnchorPhysics(followLatest: false);

      expect(
        physics.adjustPositionForNewDimensions(
          oldPosition: _metrics(pixels: 400, maxScrollExtent: 400),
          newPosition: _metrics(pixels: 400, maxScrollExtent: 460),
          isScrolling: false,
          velocity: 0,
        ),
        400,
      );
    },
  );

  test('active area combines a concurrent upward drag with growth', () {
    const physics = TerminalScrollAnchorPhysics();

    expect(
      physics.adjustPositionForNewDimensions(
        oldPosition: _metrics(pixels: 400, maxScrollExtent: 400),
        newPosition: _metrics(pixels: 385, maxScrollExtent: 460),
        isScrolling: true,
        velocity: 0,
      ),
      445,
    );
  });

  test('preserves bottom overscroll relative to a growing extent', () {
    const physics = TerminalScrollAnchorPhysics();

    expect(
      physics.adjustPositionForNewDimensions(
        oldPosition: _metrics(pixels: 420, maxScrollExtent: 400),
        newPosition: _metrics(pixels: 420, maxScrollExtent: 460),
        isScrolling: true,
        velocity: 0,
      ),
      480,
    );
  });
}

FixedScrollMetrics _metrics({
  required double pixels,
  required double maxScrollExtent,
}) {
  return FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: maxScrollExtent,
    pixels: pixels,
    viewportDimension: 300,
    axisDirection: AxisDirection.down,
    devicePixelRatio: 1,
  );
}
