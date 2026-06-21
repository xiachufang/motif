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
          builder: (_) => const Column(
            children: [
              AdaptiveModalHeader(title: 'Panel'),
              Text('Panel body'),
            ],
          ),
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

  testWidgets('adaptive panel stays below status bar with keyboard', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    try {
      await _pumpHost(
        tester,
        onOpen: (context) => showAdaptivePanel<void>(
          context,
          builder: (_) => const Column(
            children: [
              AdaptiveModalHeader(title: 'Panel'),
              Expanded(child: SizedBox()),
            ],
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final headerTop = tester.getTopLeft(find.byType(AdaptiveModalHeader)).dy;
      expect(headerTop, greaterThanOrEqualTo(47 + MotifSpacing.sm));
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
