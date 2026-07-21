import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/workspace/workspace_api.dart';
import 'package:motif/motif/state/workspace/workspace_content_view_model.dart';
import 'package:motif/motif/ui/screens/file_tree_panel.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';

final class _FakeWorkspace {
  late final WorkspaceApi api = WorkspaceApi(
    content: WorkspaceContentViewModel(),
    transport: WorkspaceApiTransport(
      isAvailable: () => true,
      call: (method, [params = const {}]) async {
        if (method != 'fs.tree') return const {};
        return {
          'entries': [
            {'name': 'AllSunday', 'type': 'dir', 'size': 0, 'mtime': 0},
            {'name': 'alma', 'type': 'dir', 'size': 0, 'mtime': 0},
          ],
        };
      },
      writeFileBytes: (_, _) async => '',
    ),
    activeCwd: () => '/Users/feichao',
  );
}

void main() {
  testWidgets('file tree uses compact rows with full-size actions', (
    tester,
  ) async {
    final workspace = _FakeWorkspace();
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 640,
            child: FileTreePanel(
              root: '/Users/feichao',
              workspace: workspace.api,
              embedded: true,
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = find.byKey(
      const ValueKey('file-tree-row:/Users/feichao/AllSunday'),
    );
    final second = find.byKey(
      const ValueKey('file-tree-row:/Users/feichao/alma'),
    );
    expect(tester.getSize(first).height, 48);
    expect(tester.getTopLeft(second).dy - tester.getTopLeft(first).dy, 48);
    expect(
      tester
          .getSize(
            find.descendant(
              of: first,
              matching: find.byType(PopupMenuButton<String>),
            ),
          )
          .height,
      40,
    );
  });
}
