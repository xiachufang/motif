import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/desktop_update_dialog.dart';
import 'package:motif/motif/update/desktop_update_download.dart';
import 'package:motif/motif/update/desktop_update_service.dart';

void main() {
  final update = DesktopUpdate(
    version: '1.2.3',
    releaseUrl: Uri.parse('https://github.com/xiachufang/motif/releases/1.2.3'),
    downloadUrl: Uri.parse(
      'https://github.com/xiachufang/motif/releases/download/v1.2.3/Motif-notarized.dmg',
    ),
    fileName: 'Motif-notarized.dmg',
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    size: 123,
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

    final download = find.widgetWithText(FilledButton, 'Download and open');
    final later = find.widgetWithText(TextButton, 'Remind me later');
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

  testWidgets('downloads the platform asset and opens it before dismissing', (
    tester,
  ) async {
    final downloader = _FakeDownloader();

    await _pumpHost(
      tester,
      onOpen: (context) =>
          showDesktopUpdateDialog(context, update, downloader: downloader),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download and open'));
    await tester.pumpAndSettle();

    expect(downloader.update, same(update));
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
            .getTopLeft(find.widgetWithText(TextButton, 'Remind me later'))
            .dy,
      ),
    );

    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(skipped, isTrue);
    expect(find.text('Motif 1.2.3 is ready'), findsNothing);
  });
}

class _FakeDownloader implements DesktopUpdateDownloadController {
  DesktopUpdate? update;

  @override
  Future<DesktopUpdateDownloadResult> downloadAndOpen(
    DesktopUpdate update, {
    void Function(DesktopUpdateDownloadProgress progress)? onProgress,
  }) async {
    this.update = update;
    onProgress?.call(
      DesktopUpdateDownloadProgress(
        receivedBytes: update.size,
        totalBytes: update.size,
      ),
    );
    return const DesktopUpdateDownloadResult(
      path: '/tmp/Motif-notarized.dmg',
      reused: false,
    );
  }
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
