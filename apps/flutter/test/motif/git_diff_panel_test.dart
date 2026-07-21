import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/workspace/workspace_api.dart';
import 'package:motif/motif/state/workspace/workspace_content_view_model.dart';
import 'package:motif/motif/ui/screens/git_diff_panel.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';

class _DiffWorkspace {
  final diffPaths = <String?>[];
  late final WorkspaceApi api;

  static const _files = [
    DiffSummaryFile(
      path: 'lib/motif/ui/screens/git_diff_panel.dart',
      additions: 12,
      deletions: 3,
    ),
    DiffSummaryFile(
      path: 'test/motif/git_diff_panel_test.dart',
      additions: 5,
      deletions: 1,
    ),
  ];

  _DiffWorkspace() {
    api = WorkspaceApi(
      content: WorkspaceContentViewModel(),
      transport: WorkspaceApiTransport(
        isAvailable: () => true,
        call: (method, [params = const {}]) async {
          if (method == 'git.diffSummary') {
            return {
              'files': [
                for (final file in _files)
                  {
                    'path': file.path,
                    'additions': file.additions,
                    'deletions': file.deletions,
                  },
              ],
            };
          }
          if (method == 'git.diff') {
            return {'patch': _diff(params['path'] as String?)};
          }
          return const {};
        },
        writeFileBytes: (_, _) async => '',
      ),
      activeCwd: () => '/work',
    );
  }

  String _diff(String? path) {
    diffPaths.add(path);
    if (path == null) {
      return [
        for (final file in _files) ...[
          'diff --git a/${file.path} b/${file.path}',
          'index abc123..def456 100644',
          '--- a/${file.path}',
          '+++ b/${file.path}',
          '@@ -1,1 +1,1 @@',
          '+changed ${file.path}',
        ],
      ].join('\n');
    }
    return [
      'diff --git a/$path b/$path',
      'index abc123..def456 100644',
      '--- a/$path',
      '+++ b/$path',
      '@@ -1,1 +1,1 @@',
      '+${'very_long_diff_line_' * 18}',
    ].join('\n');
  }
}

void main() {
  testWidgets('embedded panel lists changed files and opens diff tabs', (
    tester,
  ) async {
    final motif = _DiffWorkspace();
    final opened = <({String? path, bool staged})>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 420,
            child: GitDiffPanel(
              workspace: motif.api,
              cwd: '/work',
              embedded: true,
              onOpenDiff: ({path, required staged}) async {
                opened.add((path: path, staged: staged));
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Git diff'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey(
          'diff-list-file-lib/motif/ui/screens/git_diff_panel.dart',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('git_diff_panel.dart'), findsOneWidget);
    expect(find.text('git_diff_panel_test.dart'), findsOneWidget);
    expect(find.byTooltip('Show diff'), findsOneWidget);
    expect(motif.diffPaths, isEmpty);
    expect(
      tester
          .getCenter(
            find.byWidgetPredicate((widget) => widget is SegmentedButton<bool>),
          )
          .dx,
      greaterThan(160),
    );
    expect(
      tester
          .getCenter(
            find.byWidgetPredicate((widget) => widget is SegmentedButton<bool>),
          )
          .dy,
      closeTo(tester.getCenter(find.text('Git diff')).dy, 1),
    );
    expect(
      tester
          .getSize(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'Tree view',
            ),
          )
          .width,
      48,
    );

    await tester.tap(
      find.byKey(
        const ValueKey(
          'diff-list-file-lib/motif/ui/screens/git_diff_panel.dart',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(motif.diffPaths, isEmpty);
    expect(opened, [
      (path: 'lib/motif/ui/screens/git_diff_panel.dart', staged: false),
    ]);

    await tester.tap(find.byTooltip('Show diff'));
    await tester.pumpAndSettle();

    expect(opened, [
      (path: 'lib/motif/ui/screens/git_diff_panel.dart', staged: false),
      (path: null, staged: false),
    ]);
  });

  testWidgets('embedded panel can switch to a changed-file tree', (
    tester,
  ) async {
    final motif = _DiffWorkspace();
    final opened = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 520,
            child: GitDiffPanel(
              workspace: motif.api,
              cwd: '/work',
              embedded: true,
              onOpenDiff: ({path, required staged}) async => opened.add(path),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Tree view'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('List view'), findsOneWidget);
    expect(find.byKey(const ValueKey('diff-tree-dir-lib')), findsOneWidget);

    for (final dir in [
      'lib',
      'lib/motif',
      'lib/motif/ui',
      'lib/motif/ui/screens',
    ]) {
      await tester.tap(find.byKey(ValueKey('diff-tree-dir-$dir')));
      await tester.pumpAndSettle();
    }

    await tester.tap(
      find.byKey(
        const ValueKey(
          'diff-tree-file-lib/motif/ui/screens/git_diff_panel.dart',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(opened, ['lib/motif/ui/screens/git_diff_panel.dart']);
  });

  testWidgets('diff view renders a concrete patch', (tester) async {
    final motif = _DiffWorkspace();
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 420,
            child: GitDiffView(
              workspace: motif.api,
              cwd: '/work',
              path: 'lib/motif/ui/screens/git_diff_panel.dart',
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(motif.diffPaths, ['lib/motif/ui/screens/git_diff_panel.dart']);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(
      find.text(
        'diff --git a/lib/motif/ui/screens/git_diff_panel.dart b/lib/motif/ui/screens/git_diff_panel.dart',
      ),
      findsNothing,
    );
    expect(find.text('index abc123..def456 100644'), findsNothing);
    expect(
      find.text('--- a/lib/motif/ui/screens/git_diff_panel.dart'),
      findsNothing,
    );
    expect(
      find.text('+++ b/lib/motif/ui/screens/git_diff_panel.dart'),
      findsNothing,
    );
    expect(find.text('@@ -1,1 +1,1 @@'), findsNothing);
    expect(find.textContaining('very_long_diff_line_'), findsOneWidget);
  });

  testWidgets('diff view groups full patch by changed file', (tester) async {
    final motif = _DiffWorkspace();
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 72,
            child: GitDiffView(
              workspace: motif.api,
              cwd: '/work',
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(motif.diffPaths, [null]);
    expect(find.text('2 changed files'), findsNothing);
    expect(find.text('git_diff_panel.dart'), findsOneWidget);
    expect(
      find.text(
        'diff --git a/lib/motif/ui/screens/git_diff_panel.dart b/lib/motif/ui/screens/git_diff_panel.dart',
      ),
      findsNothing,
    );
    expect(
      find.text(
        'diff --git a/test/motif/git_diff_panel_test.dart b/test/motif/git_diff_panel_test.dart',
      ),
      findsNothing,
    );
    expect(find.text('index abc123..def456 100644'), findsNothing);
    expect(find.text('@@ -1,1 +1,1 @@'), findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(find.text('git_diff_panel.dart'), findsNothing);
    expect(find.text('git_diff_panel_test.dart'), findsOneWidget);
  });

  testWidgets('diff view sections can collapse and expand', (tester) async {
    final motif = _DiffWorkspace();
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 240,
            child: GitDiffView(
              workspace: motif.api,
              cwd: '/work',
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const line = '+changed lib/motif/ui/screens/git_diff_panel.dart';
    const headerKey = ValueKey(
      'diff-section-header-lib/motif/ui/screens/git_diff_panel.dart',
    );

    expect(find.text(line), findsOneWidget);

    await tester.tap(find.byKey(headerKey));
    await tester.pumpAndSettle();

    expect(find.text(line), findsNothing);

    await tester.tap(find.byKey(headerKey));
    await tester.pumpAndSettle();

    expect(find.text(line), findsOneWidget);
  });
}
