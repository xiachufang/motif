import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/desktop_update_dialog.dart';
import 'package:motif/motif/update/desktop_update_service.dart';

void main() {
  final update = DesktopUpdate(
    version: '1.2.3',
    releaseUrl: Uri.parse('https://github.com/xiachufang/motif/releases/1.2.3'),
    title: 'Motif 1.2.3',
  );

  testWidgets('presents update actions as a clear vertical hierarchy', (
    tester,
  ) async {
    await _pumpHost(
      tester,
      onOpen: (context) => showDesktopUpdateDialog(context, update),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Motif 1.2.3 is ready'), findsOneWidget);
    expect(find.byIcon(Icons.system_update_alt_rounded), findsOneWidget);
    expect(find.byType(CloseButton), findsNothing);

    final download = find.widgetWithText(FilledButton, 'Download update');
    final later = find.widgetWithText(OutlinedButton, 'Remind me later');
    expect(download, findsOneWidget);
    expect(later, findsOneWidget);
    expect(
      tester.getTopLeft(download).dy,
      lessThan(tester.getTopLeft(later).dy),
    );

    await tester.tap(later);
    await tester.pumpAndSettle();
    expect(find.text('Motif 1.2.3 is ready'), findsNothing);
  });

  testWidgets('skip version remains a low-priority dismiss action', (
    tester,
  ) async {
    var skipped = false;

    await _pumpHost(
      tester,
      onOpen: (context) => showDesktopUpdateDialog(
        context,
        update,
        onSkipVersion: () async => skipped = true,
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final skip = find.widgetWithText(TextButton, 'Skip this version');
    expect(skip, findsOneWidget);
    expect(
      tester.getTopLeft(skip).dy,
      greaterThan(
        tester
            .getTopLeft(find.widgetWithText(OutlinedButton, 'Remind me later'))
            .dy,
      ),
    );

    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(skipped, isTrue);
    expect(find.text('Motif 1.2.3 is ready'), findsNothing);
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
