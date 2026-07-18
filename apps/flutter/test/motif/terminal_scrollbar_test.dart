import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_scrollbar.dart';

void main() {
  test('return-to-cursor visibility requires history and visible controls', () {
    expect(
      terminalReturnToCursorShouldBeVisible(
        controlsVisible: true,
        hasScrollback: true,
        alternateScreenActive: false,
        isAtLatest: false,
      ),
      isTrue,
    );

    for (final state in [
      (
        controlsVisible: false,
        hasScrollback: true,
        alternateScreenActive: false,
        isAtLatest: false,
      ),
      (
        controlsVisible: true,
        hasScrollback: false,
        alternateScreenActive: false,
        isAtLatest: false,
      ),
      (
        controlsVisible: true,
        hasScrollback: true,
        alternateScreenActive: true,
        isAtLatest: false,
      ),
      (
        controlsVisible: true,
        hasScrollback: true,
        alternateScreenActive: false,
        isAtLatest: true,
      ),
    ]) {
      expect(
        terminalReturnToCursorShouldBeVisible(
          controlsVisible: state.controlsVisible,
          hasScrollback: state.hasScrollback,
          alternateScreenActive: state.alternateScreenActive,
          isAtLatest: state.isAtLatest,
        ),
        isFalse,
        reason: '$state',
      );
    }
  });

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

    controller.showTemporarily();
    controller.setReturnButtonHovered(true);
    controller.setHovered(true);
    controller.setReturnButtonHovered(false);
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

  test('return-to-cursor hit rectangle matches its positioned layout', () {
    final rect = TerminalReturnToCursorButton.hitRectForViewport(
      const Size(320, 200),
    );

    expect(rect, const Rect.fromLTWH(256, 148, 40, 40));
    expect(rect.contains(const Offset(276, 168)), isTrue);
    expect(rect.contains(const Offset(300, 190)), isFalse);
  });

  testWidgets(
    'return-to-cursor button fades, ignores taps, and handles hover',
    (tester) async {
      var presses = 0;
      final hoverChanges = <bool>[];

      Future<void> pumpButton({required bool visible}) {
        return tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: TerminalReturnToCursorButton(
                visible: visible,
                foregroundColor: Colors.white,
                backgroundColor: Colors.black,
                onPressed: () => presses++,
                onHoverChanged: hoverChanges.add,
              ),
            ),
          ),
        );
      }

      await pumpButton(visible: false);
      var opacity = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('terminal-return-to-cursor-opacity')),
      );
      expect(opacity.opacity, 0);
      await tester.tap(
        find.byKey(const ValueKey('terminal-return-to-cursor-button')),
        warnIfMissed: false,
      );
      expect(presses, 0);

      await pumpButton(visible: true);
      await tester.pumpAndSettle();
      opacity = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('terminal-return-to-cursor-opacity')),
      );
      expect(opacity.opacity, 1);
      final button = find.byKey(
        const ValueKey('terminal-return-to-cursor-button'),
      );
      expect(tester.getSize(button), const Size.square(40));
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);

      await tester.tap(button);
      expect(presses, 1);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(button));
      await tester.pump();
      expect(hoverChanges.last, isTrue);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      expect(hoverChanges.last, isFalse);
      await mouse.removePointer();
    },
  );

  testWidgets('shared scroll controls drive scrollbar and return action', (
    tester,
  ) async {
    final controller = TerminalScrollbarVisibilityController();
    addTearDown(controller.dispose);
    final offsets = <int>[];
    var returns = 0;
    controller.updateCanShow(true);
    controller.showTemporarily();

    Widget controls({int viewportOffset = 40, bool alternate = false}) {
      return MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            height: 200,
            child: TerminalScrollControls(
              totalRows: 100,
              visibleRows: 20,
              viewportOffset: viewportOffset,
              alternateScreenActive: alternate,
              visibilityController: controller,
              thumbColor: Colors.white,
              trackColor: Colors.white24,
              buttonForegroundColor: Colors.white,
              buttonBackgroundColor: Colors.black,
              onScrollToOffset: offsets.add,
              onScrollbarHoverChanged: controller.setHovered,
              onReturnButtonHoverChanged: controller.setReturnButtonHovered,
              onScrollbarActivity: controller.showTemporarily,
              onScrollbarDragStart: controller.beginDrag,
              onScrollbarDragEnd: controller.endDrag,
              onReturnToCursor: () => returns++,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(controls());
    expect(
      find.byKey(const ValueKey('terminal-scrollbar-hot-zone')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('terminal-return-to-cursor-opacity')),
          )
          .opacity,
      1,
    );
    await tester.tap(
      find.byKey(const ValueKey('terminal-return-to-cursor-button')),
    );
    expect(returns, 1);

    await tester.tapAt(const Offset(312, 190));
    await tester.pump();
    expect(offsets.last, 60);

    await tester.pumpWidget(controls(viewportOffset: 80));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('terminal-return-to-cursor-opacity')),
          )
          .opacity,
      0,
    );

    await tester.pumpWidget(controls(alternate: true));
    expect(
      find.byKey(const ValueKey('terminal-scrollbar-hot-zone')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
