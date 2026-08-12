import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_agent_output_parser.dart';

void main() {
  const parser = CodexAgentOutputParser();

  test('hides git directives but preserves fenced examples', () {
    const text =
        'Done.\n\n'
        '::git-stage{cwd="/work/motif"}\n'
        '::git-commit{cwd="/work/motif"}\n\n'
        '```text\n'
        '::git-stage{cwd="example"}\n'
        '```';

    final visible = parser.parse(text);

    expect(visible, isNot(contains('cwd="/work/motif"')));
    expect(visible, contains('::git-stage{cwd="example"}'));
  });
}
