import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/generate_codex_app_server_protocol.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';

void main() {
  test('thread project filters preserve omitted versus explicit null', () {
    expect(
      const CodexThreadListParams().toJson().containsKey('projectId'),
      isFalse,
    );
    expect(
      const CodexThreadListParams(projectIdSpecified: true).toJson(),
      containsPair('projectId', null),
    );
    expect(
      CodexThreadListParams.fromJson({'projectId': null}).toJson(),
      containsPair('projectId', null),
    );
    expect(
      const CodexThreadListParams(projectId: 'project').toJson(),
      containsPair('projectId', 'project'),
    );
  });

  test('generator retains nullable thread project filter presence', () async {
    final document =
        jsonDecode(
              await File(
                'test/fixtures/codex_protocol_schema.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    (document['definitions'] as Map<String, dynamic>)['ThreadListParams'] = {
      'type': 'object',
      'properties': {
        'projectId': {
          'type': ['string', 'null'],
        },
      },
    };
    final generated = generateCodexProtocolSource(
      utf8.encode(jsonEncode(document)),
      codexVersion: 'test',
    );
    expect(generated, contains('this.projectIdSpecified = false'));
    expect(
      generated,
      contains("projectIdSpecified: map.containsKey('projectId')"),
    );
    expect(
      generated,
      contains("if (projectIdSpecified || projectId != null) 'projectId'"),
    );
  });

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
