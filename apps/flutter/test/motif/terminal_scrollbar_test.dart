import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_scrollbar.dart';

void main() {
  test('thumb geometry reflects viewport fraction and offset', () {
    final geometry = TerminalScrollbarGeometry.calculate(
      trackExtent: 200,
      totalRows: 100,
      visibleRows: 20,
      viewportOffset: 40,
    );

    expect(geometry.thumbExtent, 40);
    expect(geometry.thumbOffset, 80);
    expect(geometry.maxOffset, 80);
    expect(geometry.offsetForThumbTop(0), 0);
    expect(geometry.offsetForThumbTop(160), 80);
  });

  test('thumb enforces a usable minimum size and clamps offsets', () {
    final geometry = TerminalScrollbarGeometry.calculate(
      trackExtent: 120,
      totalRows: 10000,
      visibleRows: 20,
      viewportOffset: 20000,
    );

    expect(geometry.thumbExtent, 28);
    expect(geometry.currentOffset, geometry.maxOffset);
    expect(geometry.thumbOffset, 92);
  });

  test('track clicks page by one visible viewport', () {
    final geometry = TerminalScrollbarGeometry.calculate(
      trackExtent: 200,
      totalRows: 100,
      visibleRows: 20,
      viewportOffset: 40,
    );

    expect(geometry.pageTargetForPointer(20), 20);
    expect(geometry.pageTargetForPointer(100), 40);
    expect(geometry.pageTargetForPointer(180), 60);
  });

  testWidgets('visibility auto-hides but stays visible for hover and drag', (
    tester,
  ) async {
    final controller = TerminalScrollbarVisibilityController(
      hideDelay: const Duration(milliseconds: 500),
    );
    addTearDown(controller.dispose);

    controller.updateCanShow(true);
    controller.showTemporarily();
    expect(controller.visible, isTrue);
    await tester.pump(const Duration(milliseconds: 499));
    expect(controller.visible, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.visible, isFalse);

    controller.setHovered(true);
    expect(controller.visible, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.visible, isTrue);
    controller.setHovered(false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.visible, isFalse);

    controller.beginDrag();
    expect(controller.visible, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.visible, isTrue);
    controller.endDrag();
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.visible, isFalse);

    controller.showTemporarily();
    controller.updateCanShow(false);
    expect(controller.visible, isFalse);
  });

  testWidgets('overlay pages and drags to absolute offsets', (tester) async {
    final offsets = <int>[];
    var dragStarts = 0;
    var dragEnds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: TerminalScrollbarOverlay.hitWidth,
            height: 200,
            child: TerminalScrollbarOverlay(
              totalRows: 100,
              visibleRows: 20,
              viewportOffset: 40,
              visible: true,
              thumbColor: Colors.white,
              trackColor: Colors.white24,
              onScrollToOffset: offsets.add,
              onHoverChanged: (_) {},
              onActivity: () {},
              onDragStart: () => dragStarts++,
              onDragEnd: () => dragEnds++,
            ),
          ),
        ),
      ),
    );

    final thumb = find.byKey(const ValueKey('terminal-scrollbar-thumb'));
    expect(tester.getSize(thumb).height, 40);
    expect(tester.getTopLeft(thumb).dy, 80);

    await tester.tapAt(const Offset(8, 180));
    await tester.pump();
    expect(offsets.last, 60);

    final drag = await tester.startGesture(tester.getCenter(thumb));
    await drag.moveTo(Offset(tester.getCenter(thumb).dx, 199));
    await drag.up();
    await tester.pump();
    expect(dragStarts, 1);
    expect(dragEnds, 1);
    expect(offsets.last, 80);
  });
}
