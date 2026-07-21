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

  testWidgets('visibility auto-hides but stays visible for button hover', (
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

    controller.showTemporarily();
    controller.setReturnButtonHovered(true);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.visible, isTrue);
    controller.setReturnButtonHovered(false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.visible, isFalse);

    controller.showTemporarily();
    controller.updateCanShow(false);
    expect(controller.visible, isFalse);
  });

  test('return-to-cursor hit rectangle matches its positioned layout', () {
    final rect = TerminalReturnToCursorButton.hitRectForViewport(
      const Size(320, 200),
    );

    expect(rect, const Rect.fromLTWH(268, 148, 40, 40));
    expect(rect.contains(const Offset(288, 168)), isTrue);
    expect(rect.contains(const Offset(300, 190)), isFalse);
  });

  testWidgets(
    'return-to-cursor button fades, ignores taps, and handles hover',
    (tester) async {
      var presses = 0;
      var pressStarts = 0;
      final hoverChanges = <bool>[];

      Future<void> pumpButton({required bool visible}) {
        return tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: TerminalReturnToCursorButton(
                visible: visible,
                foregroundColor: Colors.white,
                backgroundColor: Colors.black,
                onPressStart: () => pressStarts++,
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
      expect(pressStarts, 0);

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

      final touch = await tester.startGesture(tester.getCenter(button));
      expect(pressStarts, 1);
      expect(presses, 1);
      await touch.up();
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

  testWidgets('shared scroll controls drive the return action', (tester) async {
    final controller = TerminalScrollbarVisibilityController();
    addTearDown(controller.dispose);
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
              buttonForegroundColor: Colors.white,
              buttonBackgroundColor: Colors.black,
              onReturnButtonHoverChanged: controller.setReturnButtonHovered,
              onReturnToCursorInteractionStart: () {},
              onReturnToCursor: () => returns++,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(controls());
    expect(
      find.byKey(const ValueKey('terminal-scrollbar-hot-zone')),
      findsNothing,
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
