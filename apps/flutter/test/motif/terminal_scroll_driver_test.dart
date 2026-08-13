import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_scroll_driver.dart';

void main() {
  testWidgets('pointer scrolling overshoots and springs back at an edge', (
    tester,
  ) async {
    final controller = TerminalScrollController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 100,
          height: 100,
          child: ListView(
            controller: controller,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            children: const [SizedBox(height: 500)],
          ),
        ),
      ),
    );
    final edge = controller.position.maxScrollExtent;
    controller.jumpTo(edge);

    controller.terminalPosition.pointerScroll(40);
    expect(controller.offset, greaterThan(edge));

    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(edge, 0.01));
    controller.dispose();
  });

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

  test('Flutter pixels map to Ghostty forward row anchors', () {
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

  test('overscroll keeps Ghostty anchored at the nearest boundary', () {
    expect(
      terminalViewportPositionFromScrollPixels(
        scrollPixels: -12,
        maxOffset: 30,
        rowHeight: 20,
      ),
      (viewportOffset: 0, pixelRemainder: 0),
    );
    expect(
      terminalViewportPositionFromScrollPixels(
        scrollPixels: 612,
        maxOffset: 30,
        rowHeight: 20,
      ),
      (viewportOffset: 30, pixelRemainder: 0),
    );
  });

  test('fractional viewport keeps only the floor remainder for overscan', () {
    final position = terminalViewportPositionFromScrollPixels(
      scrollPixels: 207,
      maxOffset: 30,
      rowHeight: 20,
    );

    expect(position.viewportOffset, 10);
    expect(position.pixelRemainder, 7);
    expect(position.pixelRemainder, greaterThanOrEqualTo(0));
    expect(position.pixelRemainder, lessThan(20));
  });

  test(
    'crossing a row moves the integer anchor and preserves the fraction',
    () {
      final before = terminalViewportPositionFromScrollPixels(
        scrollPixels: 219.9,
        maxOffset: 30,
        rowHeight: 20,
      );
      final after = terminalViewportPositionFromScrollPixels(
        scrollPixels: 220.1,
        maxOffset: 30,
        rowHeight: 20,
      );

      expect(before.viewportOffset, 10);
      expect(before.pixelRemainder, closeTo(19.9, 1e-9));
      expect(after.viewportOffset, 11);
      expect(after.pixelRemainder, closeTo(0.1, 1e-9));
    },
  );

  test('adjacent stale snapshots use the matching fixed overscan side', () {
    final before = TerminalViewportProjection.calculate(
      scrollPixels: 256.94 * 15,
      rowHeight: 15,
      maxViewportOffset: 300,
      maxScrollPixels: 4500,
      snapshotViewportOffset: 257,
      snapshotIsLive: false,
      followsLatest: false,
    );
    final after = TerminalViewportProjection.calculate(
      scrollPixels: 257.06 * 15,
      rowHeight: 15,
      maxViewportOffset: 300,
      maxScrollPixels: 4500,
      snapshotViewportOffset: 257,
      snapshotIsLive: false,
      followsLatest: false,
    );

    expect(before.paintOffset, closeTo(-0.9, 1e-9));
    expect(before.target, (offset: 256, latest: false));
    expect(after.paintOffset, closeTo(0.9, 1e-9));
    expect(after.target, (offset: 257, latest: false));
  });

  test('history projection translates both overscroll boundaries', () {
    final top = TerminalViewportProjection.calculate(
      scrollPixels: -12,
      rowHeight: 20,
      maxViewportOffset: 30,
      maxScrollPixels: 600,
      snapshotViewportOffset: 0,
      snapshotIsLive: false,
      followsLatest: false,
    );
    final bottom = TerminalViewportProjection.calculate(
      scrollPixels: 612,
      rowHeight: 20,
      maxViewportOffset: 30,
      maxScrollPixels: 600,
      snapshotViewportOffset: 30,
      snapshotIsLive: false,
      followsLatest: false,
    );

    expect(top.paintOffset, -12);
    expect(top.target, (offset: 0, latest: false));
    expect(bottom.paintOffset, 12);
    expect(bottom.target, (offset: 30, latest: false));
  });

  test('live snapshot uses only bottom elastic displacement during output', () {
    final overscrolled = TerminalViewportProjection.calculate(
      scrollPixels: 420,
      rowHeight: 20,
      maxViewportOffset: 20,
      maxScrollPixels: 400,
      snapshotViewportOffset: 20,
      snapshotIsLive: true,
      followsLatest: true,
    );
    final inside = TerminalViewportProjection.calculate(
      scrollPixels: 390,
      rowHeight: 20,
      maxViewportOffset: 20,
      maxScrollPixels: 400,
      snapshotViewportOffset: 20,
      snapshotIsLive: true,
      followsLatest: true,
    );

    expect(overscrolled.paintOffset, 20);
    expect(overscrolled.target, (offset: 20, latest: true));
    expect(inside.paintOffset, 0);
    expect(inside.visualRowOffset, 19.5);
    expect(inside.target, (offset: 20, latest: true));
  });

  testWidgets('scroll position owns auto-follow intent', (tester) async {
    final controller = TerminalScrollController()
      ..autoFollowThresholdPixels = 20;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 100,
          height: 100,
          child: ListView(
            controller: controller,
            physics: const BouncingScrollPhysics(),
            children: const [SizedBox(height: 500)],
          ),
        ),
      ),
    );
    final edge = controller.position.maxScrollExtent;
    controller.jumpTo(edge);

    controller.terminalPosition.pointerScroll(-1);
    expect(controller.followsLatest, isFalse);
    controller.terminalPosition.pointerScroll(-30);
    controller.terminalPosition.pointerScroll(100);
    expect(controller.followsLatest, isTrue);
    controller.dispose();
  });

  test('extent correction follows live output and preserves elasticity', () {
    expect(
      terminalFollowCorrectionForNewDimensions(
        followsLatest: true,
        oldPixels: 400,
        oldMaxScrollExtent: 400,
        newPixels: 400,
        newMaxScrollExtent: 460,
      ),
      460,
    );
    expect(
      terminalFollowCorrectionForNewDimensions(
        followsLatest: true,
        oldPixels: 420,
        oldMaxScrollExtent: 400,
        newPixels: 420,
        newMaxScrollExtent: 460,
      ),
      480,
    );
  });

  test('extent correction preserves history and concurrent upward input', () {
    expect(
      terminalFollowCorrectionForNewDimensions(
        followsLatest: false,
        oldPixels: 120,
        oldMaxScrollExtent: 400,
        newPixels: 120,
        newMaxScrollExtent: 460,
      ),
      isNull,
    );
    expect(
      terminalFollowCorrectionForNewDimensions(
        followsLatest: true,
        oldPixels: 400,
        oldMaxScrollExtent: 400,
        newPixels: 385,
        newMaxScrollExtent: 460,
      ),
      isNull,
    );
  });
}
