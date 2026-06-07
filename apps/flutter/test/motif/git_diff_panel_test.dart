import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/ui/screens/git_diff_panel.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';

class _DiffMotifClient extends MotifClient {
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

  @override
  Future<List<DiffSummaryFile>> gitDiffSummary({
    String? path,
    bool staged = false,
    String? cwd,
  }) async {
    return _files;
  }

  @override
  Future<String> gitDiff({
    String? path,
    bool staged = false,
    String? cwd,
  }) async {
    return [
      'diff --git a/$path b/$path',
      '@@ -1,1 +1,1 @@',
      '+${'very_long_diff_line_' * 18}',
    ].join('\n');
  }
}

void main() {
  testWidgets('embedded panel adapts to narrow widths', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 420,
            child: GitDiffPanel(
              motif: _DiffMotifClient(),
              cwd: '/work',
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Git diff'), findsOneWidget);
    expect(find.byTooltip('By file'), findsOneWidget);
    expect(
      tester
          .getCenter(
            find.byWidgetPredicate((widget) => widget is SegmentedButton<bool>),
          )
          .dx,
      closeTo(120, 1),
    );
    expect(
      tester
          .getSize(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'By file',
            ),
          )
          .width,
      48,
    );

    await tester.tap(find.byTooltip('By file'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Show all'), findsOneWidget);
    expect(find.byTooltip('Files'), findsOneWidget);
  });
}
