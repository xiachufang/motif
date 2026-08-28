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

  test('extracts response annotations and the request from their prompt', () {
    final parsed = parser.parse(const [
      CodexTextUserInput(
        text: '''
# Response annotations:
Each item contains text selected from an earlier Codex response.
<response-annotations>
[{"text":"再点其他位置会移动分割线；取消则不保存。","annotation":"什么意思？"},{"text":"第二段选择"}]
</response-annotations>

## My request:
可以 split 后，不退出接着 split 吗？
''',
      ),
    ]);

    expect(parsed.text, '可以 split 后，不退出接着 split 吗？');
    expect(parsed.responseAnnotations, hasLength(2));
    expect(parsed.responseAnnotations.first.text, '再点其他位置会移动分割线；取消则不保存。');
    expect(parsed.responseAnnotations.first.annotation, '什么意思？');
    expect(parsed.responseAnnotations.last.text, '第二段选择');
    expect(parsed.responseAnnotations.last.annotation, isNull);
  });

  test('supports an annotation-only request', () {
    final parsed = parser.parse(const [
      CodexTextUserInput(
        text: '''
# Response annotations:
Prompt details.
<response-annotations>
[{"text":"Selected response","annotation":"Use this approach"}]
</response-annotations>

## My request:

''',
      ),
    ]);

    expect(parsed.text, isEmpty);
    expect(parsed.responseAnnotations.single.annotation, 'Use this approach');
  });

  test('preserves malformed response annotation prompts', () {
    const prompt = '''
# Response annotations:
Prompt details.
<response-annotations>
not-json
</response-annotations>

## My request:
Keep this visible.
''';
    final parsed = parser.parse(const [CodexTextUserInput(text: prompt)]);

    expect(parsed.text, prompt);
    expect(parsed.responseAnnotations, isEmpty);
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
