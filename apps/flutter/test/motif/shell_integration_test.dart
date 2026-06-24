import 'dart:convert';
import 'dart:typed_data';

import 'package:motif/motif/net/shell_integration.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// Build an OSC sequence: `ESC ] body BEL`.
String _osc(String body) => '\x1b]$body\x07';

void main() {
  group('OscScanner passthrough', () {
    test('plain bytes pass through unchanged', () {
      final st = ShellState();
      final r = st.feed(_b('hello world'));
      expect(utf8.decode(r.passthrough), 'hello world');
      expect(r.events, isEmpty);
    });

    test('unknown OSC passes through verbatim', () {
      final st = ShellState();
      // OSC 0 (set window title) is not a shell-integration marker.
      final r = st.feed(_b('a${_osc('0;my title')}b'));
      expect(utf8.decode(r.passthrough), 'a${_osc('0;my title')}b');
    });
  });

  group('prompt → command → output state machine', () {
    test('full block cycle emits the expected events', () {
      final st = ShellState();

      final r1 = st.feed(_b(_osc('133;A')));
      expect(r1.events.whereType<ShellBootstrapped>(), isNotEmpty);
      final promptStart = r1.events.whereType<ShellPromptStarted>().single;
      expect(st.activeScope, ShellOutputScope.prompt);

      final r2 = st.feed(_b(_osc('133;B')));
      expect(
        r2.events.whereType<ShellPromptEnded>().single.blockId,
        promptStart.blockId,
      );
      expect(st.activeScope, ShellOutputScope.command);

      // Stash explicit command text via OSC 777;E (hex of "ls -la").
      final hex = utf8
          .encode('ls -la')
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      st.feed(_b(_osc('777;E;$hex')));

      final r3 = st.feed(_b(_osc('133;C')));
      final started = r3.events.whereType<ShellCommandStarted>().single;
      expect(started.text, 'ls -la');
      expect(st.activeScope, ShellOutputScope.output);

      final r4 = st.feed(_b(_osc('133;D;0')));
      final finished = r4.events.whereType<ShellCommandFinished>().single;
      expect(finished.exitCode, 0);
      expect(finished.blockId, promptStart.blockId);
      expect(st.activeScope, ShellOutputScope.passthrough);
    });

    test('cwd change via OSC 7 emits cwdChanged', () {
      final st = ShellState();
      final r = st.feed(_b(_osc('7;file://host/Users/me/dev')));
      final ev = r.events.whereType<ShellCwdChanged>().single;
      expect(ev.cwd, '/Users/me/dev');
    });

    test('OSC 777;P;Context decodes a context map', () {
      final st = ShellState();
      final json = jsonEncode({'branch': 'main', 'venv': 'env'});
      final hex = utf8
          .encode(json)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final r = st.feed(_b(_osc('777;P;Context=$hex')));
      final ev = r.events.whereType<ShellContextEvent>().single;
      expect(ev.ctx['branch'], 'main');
      expect(ev.ctx['venv'], 'env');
    });
  });

  test('markers split across chunk boundaries still parse', () {
    final st = ShellState();
    // Feed the OSC 133;A one byte at a time.
    final seq = _b(_osc('133;A'));
    var sawPrompt = false;
    for (final byte in seq) {
      final r = st.feed(Uint8List.fromList([byte]));
      if (r.events.whereType<ShellPromptStarted>().isNotEmpty) sawPrompt = true;
    }
    expect(sawPrompt, isTrue);
  });

  group('native 7777 markers (current shell protocol)', () {
    // The shell emits OSC 7777 (assets/shell/bash.sh); the scanner must parse
    // it, not just the legacy 777. Regression guard for the 777→7777 migration
    // (commit b4209b1) that left the Dart scanner behind.
    String hex(String s) =>
        utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    test('full block cycle drives the running-command state', () {
      final st = ShellState();
      st.feed(_b(_osc('7777;A')));
      st.feed(_b(_osc('7777;B')));
      st.feed(_b(_osc('7777;E;${hex('cargo build')}')));
      final r = st.feed(_b(_osc('7777;C')));
      final started = r.events.whereType<ShellCommandStarted>().single;
      expect(started.text, 'cargo build');
      expect(st.activeScope, ShellOutputScope.output);

      final end = st.feed(_b(_osc('7777;D;0')));
      expect(end.events.whereType<ShellCommandFinished>().single.exitCode, 0);
    });

    test('7777;P;Cwd updates cwd', () {
      final st = ShellState();
      final r = st.feed(_b(_osc('7777;P;Cwd=file:///home/me/proj')));
      expect(r.events.whereType<ShellCwdChanged>().single.cwd, '/home/me/proj');
    });
  });

  group('primeRunning (cold attach restore)', () {
    test('enters running scope without emitting a start', () {
      final st = ShellState();
      st.primeRunning('sleep 60');
      expect(st.activeScope, ShellOutputScope.output);
      expect(st.activeBlockId, isNotNull);
    });

    test('a later live command-end marker finalizes the primed command', () {
      final st = ShellState();
      st.primeRunning('sleep 60');
      final blockId = st.activeBlockId;

      // The next live `command end` marker (native 7777;D) clears the primed
      // state, self-healing the stale running-command entry.
      final r = st.feed(_b(_osc('7777;D;0')));
      final finished = r.events.whereType<ShellCommandFinished>().single;
      expect(finished.blockId, blockId);
      expect(st.activeScope, ShellOutputScope.passthrough);
    });

    test('a new prompt also finalizes the primed command', () {
      final st = ShellState();
      st.primeRunning('sleep 60');
      final r = st.feed(_b(_osc('133;A')));
      expect(r.events.whereType<ShellCommandFinished>(), isNotEmpty);
    });
  });
}
