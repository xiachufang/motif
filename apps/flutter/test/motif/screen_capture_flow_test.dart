import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/workspace/workspace_api.dart';
import 'package:motif/motif/state/workspace/workspace_content_view_model.dart';
import 'package:motif/motif/ui/screens/screen_capture_flow.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';

class _FakeCaptureWorkspace {
  final captured = <CaptureTarget>[];
  late final WorkspaceApi api = WorkspaceApi(
    content: WorkspaceContentViewModel(),
    transport: WorkspaceApiTransport(
      isAvailable: () => true,
      supportsScreenCapture: () => true,
      call: (method, [params = const {}]) async {
        expect(method, 'capture.targets');
        return {
          'available': true,
          'app_icons_png_b64': {
            'Editor':
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
                'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          },
          'displays': [
            {
              'id': 'display:1',
              'name': 'Main display',
              'width': 1920,
              'height': 1080,
              'primary': true,
            },
          ],
          'windows': [
            {
              'id': 'window:9',
              'app_name': 'Editor',
              'title': 'motif.dart',
              'width': 1200,
              'height': 800,
              'focused': true,
            },
          ],
        };
      },
      writeFileBytes: (_, _) async => '',
      captureImage: (target) async {
        captured.add(target);
        return Uint8List.fromList(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
            'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        );
      },
    ),
    activeCwd: () => '/work',
  );
}

void main() {
  testWidgets('chooses a remote target and displays the returned PNG', (
    tester,
  ) async {
    final workspace = _FakeCaptureWorkspace();
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showScreenCaptureFlow(context, workspace.api),
                child: const Text('Capture'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Capture'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('capture-target-picker')), findsOneWidget);
    expect(find.text('Main display'), findsOneWidget);
    expect(find.text('motif.dart'), findsOneWidget);
    expect(find.text('1920 × 1080 · Primary'), findsOneWidget);
    final windowTile = tester.widget<ListTile>(
      find.byKey(const ValueKey('capture-target-window-window:9')),
    );
    expect((windowTile.title as Text).data, 'Editor');
    expect((windowTile.subtitle as Text).data, 'motif.dart');
    expect(
      find.byKey(const ValueKey('capture-app-icon-Editor')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('capture-target-display-display:1')),
    );
    await tester.pumpAndSettle();

    expect(workspace.captured, hasLength(1));
    expect(workspace.captured.single.id, 'display:1');
    expect(find.byKey(const ValueKey('screen-capture-viewer')), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-capture-image')), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('capture-target-picker')), findsOneWidget);
    expect(find.text('Main display'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Capture'), findsOneWidget);
    expect(find.byKey(const ValueKey('capture-target-picker')), findsNothing);
  });
}
