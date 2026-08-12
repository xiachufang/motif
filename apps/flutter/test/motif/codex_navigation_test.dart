import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_navigation.dart';

void main() {
  test('resolves Codex Markdown file links against the thread cwd', () {
    expect(
      codexFilePathFromMarkdownLink(
        'lib/motif/codex_navigation.dart:42',
        cwd: '/work/motif',
      ),
      '/work/motif/lib/motif/codex_navigation.dart',
    );
    expect(
      codexFilePathFromMarkdownLink('README.md:12', cwd: '/work/motif'),
      '/work/motif/README.md',
    );
    expect(
      codexFilePathFromMarkdownLink('/work/motif/lib/main.dart:12:4'),
      '/work/motif/lib/main.dart',
    );
    expect(
      codexFilePathFromMarkdownLink('file:///work/motif/My%20File.dart#L8'),
      '/work/motif/My File.dart',
    );
  });

  test('does not treat web links or document anchors as files', () {
    expect(codexFilePathFromMarkdownLink('https://example.com/a.dart'), isNull);
    expect(codexFilePathFromMarkdownLink('mailto:test@example.com'), isNull);
    expect(codexFilePathFromMarkdownLink('#details'), isNull);
  });
}
