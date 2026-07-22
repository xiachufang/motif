import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_link.dart';
import 'package:motif/motif/terminal/terminal_snapshot.dart';

void main() {
  test('indexes URLs and plain file paths across the visible screen', () {
    final snapshot = _snapshot([
      _row('open https://example.com/docs.'),
      _row('see lib/motif/main.dart:42:7 and README.md'),
    ]);

    final index = TerminalLinkIndex.forScreen(snapshot);

    expect(
      index.matches.map((match) => (match.kind, match.target)),
      containsAll([
        (TerminalLinkKind.url, 'https://example.com/docs'),
        (TerminalLinkKind.filePath, 'lib/motif/main.dart:42:7'),
      ]),
    );
    expect(
      index.matches.map((match) => match.target),
      isNot(contains('README.md')),
    );
    final source = index.matches.singleWhere(
      (match) => match.target == 'lib/motif/main.dart:42:7',
    );
    expect(source.file?.path, 'lib/motif/main.dart');
    expect(source.file?.line, 42);
    expect(source.file?.column, 7);
  });

  test('OSC 8 metadata wins over text-based matching', () {
    const uri = 'https://example.com/from-osc8';
    final snapshot = _snapshot([_row('README.md', hyperlinkUri: uri)]);

    final index = TerminalLinkIndex.forScreen(snapshot);

    expect(index.matches, hasLength(1));
    expect(index.matches.single.kind, TerminalLinkKind.osc8);
    expect(index.matches.single.target, uri);
    expect(
      index.matchAt(const TerminalCellPoint(row: 0, col: 3)),
      same(index.matches.single),
    );
  });

  test('mobile lookup only scans the tapped soft-wrapped logical line', () {
    final snapshot = _snapshot(
      [
        _row('lib/long_na', wrap: true),
        _row('me.dart:9', wrapContinuation: true),
        _row('o/x.dart'),
      ],
      cols: 11,
      viewportOffset: 20,
    );

    final match = TerminalLinkMatcher.matchAt(
      snapshot,
      const TerminalCellPoint(row: 21, col: 4),
    );

    expect(match?.target, 'lib/long_name.dart:9');
    expect(match?.file?.path, 'lib/long_name.dart');
    expect(match?.file?.line, 9);
    expect(
      match?.segments
          .map((segment) => (segment.row, segment.startCol, segment.endCol))
          .toList(),
      [(20, 0, 10), (21, 0, 8)],
    );
    expect(
      TerminalLinkMatcher.matchAt(
        snapshot,
        const TerminalCellPoint(row: 22, col: 0),
      )?.target,
      'o/x.dart',
    );
  });

  test('hard line breaks do not join path fragments', () {
    final snapshot = _snapshot([_row('lib/long_'), _row('name.dart')]);

    final index = TerminalLinkIndex.forScreen(snapshot);

    expect(
      index.matches.map((match) => match.target),
      isNot(contains('lib/long_name.dart')),
    );
  });

  test('file targets resolve relative paths against terminal cwd', () {
    final target = TerminalFileTarget.tryParse('./lib/main.dart:12');

    expect(
      target?.resolveAgainst('/workspace/app'),
      '/workspace/app/lib/main.dart',
    );
    expect(target?.line, 12);
    expect(
      TerminalFileTarget.tryParse('https://example.com/file.dart'),
      isNull,
    );
  });

  test('matches Ghostty URL cases', () {
    const cases = <({String input, String expected})>[
      (
        input: 'hello https://example.com world',
        expected: 'https://example.com',
      ),
      (
        input: 'Link inside (https://example.com) parens',
        expected: 'https://example.com',
      ),
      (
        input: 'Link period https://example.com. More text.',
        expected: 'https://example.com',
      ),
      (
        input: 'https://example.com/foo(bar)baz more',
        expected: 'https://example.com/foo(bar)baz',
      ),
      (
        input: 'query https://example.com?query=1&other=2 and more',
        expected: 'https://example.com?query=1&other=2',
      ),
      (
        input: 'mail mailto:test@example.com now',
        expected: 'mailto:test@example.com',
      ),
      (input: 'call tel:+18005551234 now', expected: 'tel:+18005551234'),
      (
        input: 'download magnet:?xt=urn:btih:1234567890 now',
        expected: 'magnet:?xt=urn:btih:1234567890',
      ),
      (
        input: 'browse ipfs://QmSomeHashValue now',
        expected: 'ipfs://QmSomeHashValue',
      ),
      (
        input: 'news news:comp.infosystems.www.servers.unix now',
        expected: 'news:comp.infosystems.www.servers.unix',
      ),
      (
        input: 'Serving HTTP on :: port 8000 (http://[::]:8000/)',
        expected: 'http://[::]:8000/',
      ),
      (
        input: 'IPv6 https://[2001:db8::1]:8080/path now',
        expected: 'https://[2001:db8::1]:8080/path',
      ),
    ];

    for (final testCase in cases) {
      expect(
        _targets(testCase.input),
        contains(testCase.expected),
        reason: testCase.input,
      );
    }
  });

  test('matches Ghostty rooted and relative path cases', () {
    const cases = <({String input, String expected})>[
      (
        input: '/Users/ghostty.user/code/../example.py hello world',
        expected: '/Users/ghostty.user/code/../example.py',
      ),
      (
        input: 'first time ../example.py contributor',
        expected: '../example.py',
      ),
      (
        input: '[link](/home/user/ghostty.user/example)',
        expected: '/home/user/ghostty.user/example',
      ),
      (input: './space middle', expected: './space middle'),
      (input: '../test folder/file.txt', expected: '../test folder/file.txt'),
      (
        input: '/tmp/test folder/file.txt',
        expected: '/tmp/test folder/file.txt',
      ),
      (input: '/tmp/test  folder/file.txt', expected: '/tmp/test'),
      (input: '/tmp/foo /tmp/bar', expected: '/tmp/foo'),
      (input: '/tmp/foo.txt /tmp/bar.txt', expected: '/tmp/foo.txt'),
      (
        input: 'diff --git a/src/font/shaper.zig b/src/font/shaper.zig',
        expected: 'a/src/font/shaper.zig',
      ),
      (input: 'modified:   src/config/url.zig', expected: 'src/config/url.zig'),
      (
        input: 'lib/ghostty/terminal.zig:42:10',
        expected: 'lib/ghostty/terminal.zig:42:10',
      ),
      (input: 'src/foo.c,baz.txt', expected: 'src/foo.c'),
      (
        input: 'open ~/Documents/notes.md please',
        expected: '~/Documents/notes.md',
      ),
      (input: '~/.config/ghostty/config', expected: '~/.config/ghostty/config'),
      (
        input: r'$HOME/src/config/url.zig',
        expected: r'$HOME/src/config/url.zig',
      ),
      (input: r'foo/$BAR/baz', expected: r'foo/$BAR/baz'),
      (input: r'.foo/bar/$VAR', expected: r'.foo/bar/$VAR'),
      (input: '.config/ghostty/config', expected: '.config/ghostty/config'),
      (input: '../some/where', expected: '../some/where'),
      (input: 'foo.local/share', expected: 'foo.local/share'),
      (input: '2024/report.txt', expected: '2024/report.txt'),
      (input: './foo bar,baz', expected: './foo bar'),
      (input: './Downloads: Operation not permitted', expected: './Downloads'),
    ];

    for (final testCase in cases) {
      expect(
        _targets(testCase.input),
        contains(testCase.expected),
        reason: testCase.input,
      );
    }
  });

  test('rejects Ghostty path bad cases and ambiguous dotted tokens', () {
    const cases = <String>[
      'input/output',
      'foo/bar',
      r'$10/bar',
      r'$10/$20',
      r'$10/bar.txt',
      'foo/bar,baz.txt',
      r'foo$BAR/baz.txt',
      'foo~/bar.txt',
      '// foo bar',
      '//foo',
      'README.md',
      'example.com',
      '1.2.3',
      'v2.0.1',
      '192.168.1.1',
      '/skills',
      '/skills to list available skills',
    ];

    for (final input in cases) {
      expect(_targets(input), isEmpty, reason: input);
    }
  });

  test('keeps qualified absolute paths while rejecting slash commands', () {
    expect(_targets('/tmp/foo'), contains('/tmp/foo'));
    expect(_targets('/README.md'), contains('/README.md'));
    expect(_targets('/.config'), contains('/.config'));
    expect(_targets('/source.dart:42:7'), contains('/source.dart:42:7'));
  });
}

List<String> _targets(String text) => TerminalLinkIndex.forScreen(
  _snapshot([_row(text)]),
).matches.map((match) => match.target).toList(growable: false);

TerminalSnapshot _snapshot(
  List<TerminalSnapshotRow> lines, {
  int? cols,
  int viewportOffset = 0,
}) {
  final width =
      cols ??
      lines.fold<int>(
        1,
        (result, row) => row.cells.length > result ? row.cells.length : result,
      );
  return TerminalSnapshot(
    frameId: 7,
    cols: width,
    rows: lines.length,
    viewportOffset: viewportOffset,
    scrollTotalRows: viewportOffset + lines.length,
    scrollViewportRows: lines.length,
    backgroundArgb: 0xff000000,
    foregroundArgb: 0xffffffff,
    cursorArgb: 0xffffffff,
    cursorVisible: false,
    cursorInViewport: false,
    cursorX: -1,
    cursorY: -1,
    cursorStyle: 0,
    mouseTrackingActive: false,
    alternateScreenActive: false,
    lines: lines,
  );
}

TerminalSnapshotRow _row(
  String text, {
  bool wrap = false,
  bool wrapContinuation = false,
  String? hyperlinkUri,
}) {
  return TerminalSnapshotRow(
    wrap: wrap,
    wrapContinuation: wrapContinuation,
    cells: [
      for (var col = 0; col < text.length; col++)
        TerminalSnapshotCell(
          col: col,
          widthCells: 1,
          text: text[col],
          foregroundArgb: 0xffffffff,
          backgroundArgb: 0xff000000,
          drawsBackground: false,
          bold: false,
          italic: false,
          invisible: false,
          hasHyperlink: hyperlinkUri != null,
          hyperlinkUri: hyperlinkUri,
        ),
    ],
  );
}
