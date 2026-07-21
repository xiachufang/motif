import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/workspace/workspace_api.dart';
import 'package:motif/motif/state/workspace/workspace_content_view_model.dart';
import 'package:motif/motif/ui/screens/preview_pane.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';

final class _FakeWorkspace {
  var readCount = 0;
  late final WorkspaceApi api = WorkspaceApi(
    content: WorkspaceContentViewModel(),
    transport: WorkspaceApiTransport(
      isAvailable: () => true,
      call: (method, [params = const {}]) async {
        if (method == 'fs.read') {
          readCount++;
          return {
            'content_b64': base64Encode(utf8.encode('# README')),
            'sha256': 'sha-$readCount',
            'truncated': false,
            'binary': false,
            'mime': 'text/markdown',
          };
        }
        if (method == 'fs.write') return {'sha256': 'saved-sha'};
        return const {};
      },
      writeFileBytes: (_, _) async => '',
    ),
    activeCwd: () => '/work',
  );
}

void main() {
  testWidgets(
    'file tab has no route back action and keeps file actions right',
    (tester) async {
      final workspace = _FakeWorkspace();
      await tester.pumpWidget(
        MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open-preview'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PreviewPane(
                    path: '/work/README.md',
                    workspace: workspace.api,
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('open-preview')));
      await tester.pumpAndSettle();

      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.automaticallyImplyLeading, isFalse);
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('README.md'), findsOneWidget);

      final refresh = find.byKey(const ValueKey('preview-refresh'));
      final edit = find.byKey(const ValueKey('preview-edit-save'));
      expect(find.byTooltip('Refresh file'), findsOneWidget);
      expect(find.byTooltip('Edit file'), findsOneWidget);
      expect(tester.getCenter(refresh).dx, lessThan(tester.getCenter(edit).dx));

      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(workspace.readCount, 2);

      await tester.tap(edit);
      await tester.pump();
      expect(find.byTooltip('Save file'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    },
  );
}
