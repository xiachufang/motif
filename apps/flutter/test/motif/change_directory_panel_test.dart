import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/workspace/workspace_api.dart';
import 'package:motif/motif/state/workspace/workspace_content_view_model.dart';
import 'package:motif/motif/ui/screens/change_directory_panel.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';

class _FakeWorkspace {
  final Map<String, List<TreeEntry>> trees;
  late final WorkspaceApi api;

  _FakeWorkspace(this.trees) {
    api = WorkspaceApi(
      content: WorkspaceContentViewModel(),
      transport: WorkspaceApiTransport(
        isAvailable: () => true,
        call: (method, [params = const {}]) async {
          if (method != 'fs.tree') return const {};
          return {
            'entries': [
              for (final entry in trees[params['path']] ?? const <TreeEntry>[])
                {
                  'name': entry.name,
                  'type': entry.type.wire,
                  'size': entry.size,
                  'mtime': entry.mtime,
                },
            ],
          };
        },
        writeFileBytes: (_, _) async => '',
      ),
      activeCwd: () => '/work',
    );
  }
}

TreeEntry _dir(String name) =>
    TreeEntry(name: name, type: FileType.dir, size: 0, mtime: 0);

TreeEntry _file(String name) =>
    TreeEntry(name: name, type: FileType.file, size: 0, mtime: 0);

Future<List<String>> _pumpPanel(WidgetTester tester) async {
  final chosen = <String>[];
  final workspace = _FakeWorkspace({
    '/': [_dir('work')],
    '/work': [_dir('beta'), _dir('Alpha'), _file('notes.txt')],
    '/work/Alpha': [_dir('src')],
    '/work/beta': const [],
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: motifTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          height: 640,
          child: ChangeDirectoryPanel(
            workspace: workspace.api,
            baseDir: '/work',
            onChoose: chosen.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return chosen;
}

void main() {
  testWidgets('mirrors iOS path field filtering and first-candidate submit', (
    tester,
  ) async {
    final chosen = await _pumpPanel(tester);

    var field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '/work/');
    expect(find.text('parent'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Alpha')).dy,
      lessThan(tester.getTopLeft(find.text('beta')).dy),
    );
    expect(find.byIcon(Icons.keyboard_return), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);

    final pathRow = find.byKey(const ValueKey('change-directory-path-row'));
    final firstCandidate = find.byKey(
      const ValueKey('change-directory-candidate:Alpha'),
    );
    final firstCandidateTile = find.descendant(
      of: firstCandidate,
      matching: find.byType(ListTile),
    );
    expect(
      tester.widget<Material>(firstCandidate).type,
      MaterialType.transparency,
    );
    expect(
      tester.widget<ListTile>(firstCandidateTile).tileColor,
      MotifColors.light.accentFill(0.12),
    );
    expect(
      tester.widget<ListTile>(firstCandidateTile).visualDensity,
      const VisualDensity(vertical: -3),
    );
    expect(tester.getSize(firstCandidate).height, 44);
    expect(
      tester.getBottomLeft(pathRow).dy,
      lessThanOrEqualTo(tester.getTopLeft(firstCandidate).dy),
    );

    await tester.enterText(find.byType(TextField), '/work/b');
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsNothing);
    expect(find.text('beta'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_return), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();

    field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '/work/beta/');
    expect(find.text('No subdirectories'), findsOneWidget);

    await tester.tap(find.text('..'));
    await tester.pumpAndSettle();

    field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '/work/');

    await tester.tap(find.byKey(const ValueKey('change-directory-confirm')));
    await tester.pumpAndSettle();

    expect(chosen, ['/work']);
  });
}
