import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MotifProto decoding', () {
    test('PtyInfo decodes with defaults', () {
      final p = PtyInfo.fromJson({'id': 'p1', 'cmd': 'fish'});
      expect(p.id, 'p1');
      expect(p.cmd, 'fish');
      expect(p.cols, 80);
      expect(p.rows, 24);
      expect(p.runningCommand, isNull);
    });

    test('PtyInfo decodes running_command when present', () {
      final p = PtyInfo.fromJson({
        'id': 'p1',
        'cmd': 'fish',
        'running_command': 'sleep 60',
      });
      expect(p.runningCommand, 'sleep 60');
    });

    test('ViewSpec tagged union round-trips', () {
      final pty = ViewSpec.fromJson({'kind': 'pty', 'pty_id': 'p1'});
      expect(pty, isA<PtyViewSpec>());
      expect((pty as PtyViewSpec).ptyId, 'p1');
      expect(pty.toJson(), {'kind': 'pty', 'pty_id': 'p1'});

      final diff = ViewSpec.fromJson({'kind': 'diff', 'staged': true});
      expect(diff, isA<DiffViewSpec>());
      expect((diff as DiffViewSpec).staged, isTrue);

      final unknown = ViewSpec.fromJson({'kind': 'frobnicate'});
      expect(unknown, isA<OtherViewSpec>());
    });

    test('AttachResult decodes nested lists', () {
      final a = AttachResult.fromJson({
        'session': {'name': 's1', 'workdir': '/tmp'},
        'ptys': [
          {'id': 'p1', 'cols': 100, 'rows': 30},
        ],
        'views': [
          {
            'id': 'v1',
            'spec': {'kind': 'pty', 'pty_id': 'p1'},
          },
        ],
        'active_view': 'v1',
        'last_seq': 42,
      });
      expect(a.session?.name, 's1');
      expect(a.ptys.single.cols, 100);
      expect(a.views.single.id, 'v1');
      expect(a.activeView, 'v1');
      expect(a.lastSeq, 42);
    });

    test('ShellKind wire mapping', () {
      expect(ShellKind.fromWire('zsh'), ShellKind.zsh);
      expect(ShellKind.fromWire('weird'), ShellKind.unknown);
    });
  });

  group('settings models', () {
    test('MotifServer list round-trips through JSON', () {
      final servers = [
        const MotifServer(
          id: 'a',
          name: 'Dev',
          host: 'dev.ts.net',
          port: 7777,
          token: 'tok',
          kind: ServerKind.tailscale,
        ),
      ];
      final encoded = MotifServer.encodeList(servers);
      final decoded = MotifServer.decodeList(encoded);
      expect(decoded.single.name, 'Dev');
      expect(decoded.single.kind, ServerKind.tailscale);
      expect(decoded.single.endpoint, 'dev.ts.net:7777');
    });

    test('MotifServer SSH fields round-trip through JSON', () {
      const server = MotifServer(
        id: 'ssh-1',
        name: 'Bastion',
        host: '127.0.0.1',
        port: 7777,
        token: 'tok',
        kind: ServerKind.ssh,
        sshHost: 'bastion.example.com',
        sshPort: 2222,
        sshUsername: 'fei',
        sshAuthMethod: SshAuthMethod.privateKey,
        sshPrivateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nkey',
        sshPrivateKeyPassphrase: 'phrase',
        sshAutoInitialize: true,
      );

      final decoded = MotifServer.decodeList(MotifServer.encodeList([server]));

      expect(decoded.single.kind, ServerKind.ssh);
      expect(decoded.single.endpoint, '127.0.0.1:7777');
      expect(decoded.single.sshEndpoint, 'bastion.example.com:2222');
      expect(decoded.single.sshUsername, 'fei');
      expect(decoded.single.sshAuthMethod, SshAuthMethod.privateKey);
      expect(decoded.single.sshPrivateKey, contains('OPENSSH'));
      expect(decoded.single.sshPrivateKeyPassphrase, 'phrase');
      expect(decoded.single.sshAutoInitialize, isTrue);
    });

    test('TerminalSettings clamps font size', () {
      final s = TerminalSettings.fromJson({'fontSize': 100, 'theme': 'dark'});
      expect(s.fontSize, TerminalSettings.maxFontSize);
      expect(s.theme, TerminalThemeSetting.dark);
    });

    test('TerminalSettings defaults to 13 pt', () {
      expect(const TerminalSettings().fontSize, 13);
      expect(TerminalSettings.fromJson(const {}).fontSize, 13);
    });

    test('default quick commands are seeded and round-trip', () {
      final cmds = defaultQuickCommands();
      expect(cmds, isNotEmpty);
      final ctrl = cmds.firstWhere((c) => c.kind == QuickCommandKind.ctrl);
      final back = QuickCommand.fromJson(ctrl.toJson());
      expect(back.kind, QuickCommandKind.ctrl);
      expect(back.label, 'Ctrl');
    });

    test('default command sets seed claude and codex presets', () {
      final sets = defaultQuickCommandSets();
      expect(sets.map((s) => s.name), containsAll(['claude', 'codex']));
      for (final s in sets) {
        expect(s.matches, contains(s.name));
        expect(s.commands, isNotEmpty);
        // ids must be unique within a set (chips key off them).
        expect(s.commands.map((c) => c.id).toSet().length, s.commands.length);
        // round-trips through JSON.
        final back = QuickCommandSet.fromJson(s.toJson());
        expect(back.name, s.name);
        expect(back.commands.length, s.commands.length);
      }

      for (final agent in ['claude', 'codex']) {
        final set = sets.singleWhere((s) => s.name == agent);
        expect(
          set.commands.where((command) => command.label == '/resume'),
          hasLength(1),
        );
      }
    });

    test('programKey extracts basename of first token', () {
      expect(programKey('/usr/bin/vim file.txt'), 'vim');
      expect(programKey('claude --resume'), 'claude');
      expect(programKey('   '), isNull);
      expect(programKey(null), isNull);
    });
  });
}
