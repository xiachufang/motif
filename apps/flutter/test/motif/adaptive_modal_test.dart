import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/adaptive_modal.dart';

void main() {
  testWidgets('adaptive modal ignores desktop barrier taps', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _pumpHost(
        tester,
        onOpen: (context) => showAdaptiveModal<void>(
          context,
          builder: (_) =>
              const AdaptiveModal(title: 'Modal', content: Text('Modal body')),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Modal body'), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Modal body'), findsOneWidget);

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.text('Modal body'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('adaptive panel ignores desktop barrier taps', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _pumpHost(
        tester,
        onOpen: (context) => showAdaptivePanel<void>(
          context,
          builder: (_) =>
              const AdaptivePanel(title: 'Panel', body: Text('Panel body')),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Panel body'), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Panel body'), findsOneWidget);

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(find.text('Panel body'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('adaptive panel paints the draggable shell on phones', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pumpHost(
        tester,
        onOpen: (context) => showAdaptivePanel<void>(
          context,
          builder: (_) =>
              const AdaptivePanel(title: 'Panel', body: Text('Panel body')),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final bottomSheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      expect(bottomSheet.backgroundColor, Colors.transparent);

      final colors = Theme.of(
        tester.element(find.text('Panel body')),
      ).extension<MotifColors>()!;
      final draggableShell = find.byWidgetPredicate((widget) {
        if (widget is! Material) return false;
        return widget.color == colors.background &&
            widget.shape is RoundedRectangleBorder;
      });
      expect(draggableShell, findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('adaptive modal keeps title below the top bar with keyboard', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    try {
      await _pumpHost(
        tester,
        onOpen: (context) => showAdaptiveModal<void>(
          context,
          builder: (_) => const AdaptiveModal(
            title: 'Modal',
            content: SizedBox(height: 1000, child: TextField(autofocus: true)),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      await tester.pumpAndSettle();

      final headerTop = tester.getTopLeft(find.byType(AdaptiveModalHeader)).dy;
      expect(headerTop, greaterThanOrEqualTo(47 + kToolbarHeight));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('adaptive panel stays below status bar with keyboard', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    try {
      await _pumpHost(
        tester,
        onOpen: (context) => showAdaptivePanel<void>(
          context,
          builder: (_) => const AdaptivePanel(
            title: 'Panel',
            body: Padding(
              padding: EdgeInsets.all(MotifSpacing.lg),
              child: TextField(autofocus: true),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      await tester.pumpAndSettle();

      final headerTop = tester.getTopLeft(find.byType(AdaptiveModalHeader)).dy;
      expect(headerTop, greaterThanOrEqualTo(47 + MotifSpacing.sm));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('adaptive panel ignores keyboard focus in a sheet above it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    try {
      await _pumpHost(
        tester,
        onOpen: (context) => showAdaptivePanel<void>(
          context,
          builder: (panelContext) => AdaptivePanel(
            title: 'Panel',
            body: Column(
              children: [
                TextButton(
                  onPressed: () => showAdaptiveModal<void>(
                    panelContext,
                    builder: (_) => const AdaptiveModal(
                      title: 'Child',
                      content: TextField(autofocus: true),
                    ),
                  ),
                  child: const Text('Open child'),
                ),
                const Spacer(),
                const Text('Bottom marker'),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final markerBottomBefore = tester
          .getBottomLeft(find.text('Bottom marker'))
          .dy;

      await tester.tap(find.text('Open child'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      await tester.pumpAndSettle();

      expect(find.text('Child'), findsOneWidget);
      final markerBottomAfter = tester
          .getBottomLeft(find.text('Bottom marker'))
          .dy;
      expect(markerBottomAfter, markerBottomBefore);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required void Function(BuildContext context) onOpen,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: motifTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => onOpen(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
}
