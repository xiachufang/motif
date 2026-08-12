import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/resource_documents.dart';

void main() {
  test('turn patches aggregate repeated files and preserve source paths', () {
    final document = DiffDocument.fromFilePatches(const [
      FilePatch(
        path: 'lib/main.dart',
        sourcePath: '/work/motif/lib/main.dart',
        patch: '@@ -1 +1 @@\n-old\n+new',
      ),
      FilePatch(
        path: 'test/main_test.dart',
        sourcePath: '/work/motif/test/main_test.dart',
        patch: '@@ -0,0 +1 @@\n+test',
      ),
      FilePatch(
        path: 'lib/main.dart',
        sourcePath: '/work/motif/lib/main.dart',
        patch: '@@ -3 +3 @@\n-old again\n+new again',
      ),
    ]);

    expect(document.files, hasLength(2));
    expect(document.files.first.path, 'lib/main.dart');
    expect(document.files.first.sourcePath, '/work/motif/lib/main.dart');
    expect(document.files.first.additions, 2);
    expect(document.files.first.deletions, 2);
    expect(document.files.first.lines, [
      '-old',
      '+new',
      '',
      '-old again',
      '+new again',
    ]);
  });

  test('workspace unified patches still feed the shared document renderer', () {
    final document = DiffDocument.fromUnifiedPatch(
      patch: [
        'diff --git a/lib/a.dart b/lib/a.dart',
        'index 123..456 100644',
        '--- a/lib/a.dart',
        '+++ b/lib/a.dart',
        '@@ -1 +1 @@',
        '-before',
        '+after',
      ].join('\n'),
      summary: const [
        DiffSummaryFile(path: 'lib/a.dart', additions: 4, deletions: 3),
      ],
    );

    expect(document.files, hasLength(1));
    expect(document.files.single.path, 'lib/a.dart');
    expect(document.files.single.sourcePath, 'lib/a.dart');
    expect(document.files.single.additions, 4);
    expect(document.files.single.deletions, 3);
    expect(document.files.single.lines, ['-before', '+after']);
  });
}
