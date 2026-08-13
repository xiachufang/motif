import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_user_input_parser.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';

void main() {
  const parser = CodexUserInputParser();

  test('extracts the request from the injected attachment prompt', () {
    final parsed = parser.parse(const [
      CodexTextUserInput(
        text: '''
# Files mentioned by the user:

## screenshot.png: /tmp/screenshot.png

## notes.md: /tmp/notes.md

## My request:
Only show **this request**.
''',
      ),
      CodexLocalImageUserInput(path: '/tmp/screenshot.png'),
      CodexImageUserInput(url: 'https://example.com/image.png'),
    ]);

    expect(parsed.text, 'Only show **this request**.');
    expect(parsed.localImages.single.path, '/tmp/screenshot.png');
    expect(parsed.remoteImages.single.url, 'https://example.com/image.png');
    expect(parsed.unhandledInputs, isEmpty);
  });

  test('extracts the request from the Codex attachment prompt variant', () {
    final parsed = parser.parse(const [
      CodexTextUserInput(
        text: '''
# Files mentioned by the user:

## codex-clipboard.png: /tmp/codex-clipboard.png

## My request for Codex:
Align the start button with the report history.
''',
      ),
    ]);

    expect(parsed.text, 'Align the start button with the report history.');
  });

  test('preserves ordinary text and incomplete attachment prompts', () {
    final ordinary = parser.parse(const [
      CodexTextUserInput(text: 'Hello **Codex**'),
      CodexTextUserInput(text: 'Second paragraph'),
    ]);
    final incomplete = parser.parse(const [
      CodexTextUserInput(
        text: '# Files mentioned by the user:\n\n## screenshot.png: /tmp/a.png',
      ),
    ]);

    expect(ordinary.text, 'Hello **Codex**\n\nSecond paragraph');
    expect(
      incomplete.text,
      '# Files mentioned by the user:\n\n## screenshot.png: /tmp/a.png',
    );
  });
}
