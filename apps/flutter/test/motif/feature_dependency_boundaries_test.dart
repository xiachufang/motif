import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Codex feature does not depend on App or Session', () {
    final files = <File>[
      ...Directory('lib/motif/codex')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
      File('lib/motif/ui/screens/codex_screen.dart'),
      File('lib/motif/ui/screens/codex_thread_workspace.dart'),
      File('lib/motif/ui/screens/side_chat_screen.dart'),
    ];

    _expectNoImports(files, const [
      '/state/app/',
      'session_screen.dart',
      '/session/',
    ]);
  });

  test('Session feature does not depend on App or Codex', () {
    final files = <File>[
      ...Directory('lib/motif/session')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
      File('lib/motif/ui/screens/session_screen.dart'),
      ...Directory('lib/motif/ui/screens/session')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    ];

    _expectNoImports(files, const ['/state/app/', '/codex/']);
  });
}

void _expectNoImports(List<File> files, List<String> forbiddenFragments) {
  final violations = <String>[];
  for (final file in files) {
    final source = file.readAsStringSync();
    for (final line in source.split('\n')) {
      final trimmed = line.trimLeft();
      if (!trimmed.startsWith('import ')) continue;
      for (final fragment in forbiddenFragments) {
        if (line.contains(fragment)) {
          violations.add('${file.path}: $line');
        }
      }
    }
  }
  expect(violations, isEmpty, reason: violations.join('\n'));
}
