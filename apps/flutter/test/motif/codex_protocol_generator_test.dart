import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/generate_codex_app_server_protocol.dart';

void main() {
  test('schema generator covers fixtures and is deterministic', () async {
    final bytes = await File(
      'test/fixtures/codex_protocol_schema.json',
    ).readAsBytes();
    final first = generateCodexProtocolSource(
      bytes,
      codexVersion: 'codex-test 1.0.0',
    );
    final second = generateCodexProtocolSource(
      bytes,
      codexVersion: 'codex-test 1.0.0',
    );

    expect(second, first);
    expect(first, contains('final class CodexNode'));
    expect(first, contains('final Map<String, int> attributes'));
    expect(first, contains('final List<CodexNode> children'));
    expect(first, contains('final bool active'));
    expect(first, contains('final Null nothing'));
    expect(first, contains('CodexJson.asStringLiteral'));
    expect(first, contains('enum CodexNodeKind'));
    expect(first, contains('sealed class CodexOutcome'));
    expect(first, contains('sealed class CodexUntagged'));
    expect(first, contains('CodexUnknownMessage(map)'));
  });
}
