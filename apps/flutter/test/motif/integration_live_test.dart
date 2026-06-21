@Tags(['live'])
library;

import 'dart:convert';

import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/net/rpc_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// End-to-end test against a real `motifd`. Run a server first, e.g.:
///   cargo run -p motif-server --bin motifd -- --listen 0.0.0.0:7777 --insecure-no-auth
/// then: flutter test test/motif/integration_live_test.dart
///
/// Skips gracefully if nothing answers on 127.0.0.1:7777.
void main() {
  const host = '127.0.0.1';
  const port = 7777;

  test(
    'ping + list + attach + receive pty output',
    () async {
      final rpc = RpcClient()..connect(host: host, port: port, token: '');

      PingInfo ping;
      try {
        ping = await rpc.ping();
      } catch (e) {
        await rpc.close();
        markTestSkipped('no motifd on $host:$port ($e)');
        return;
      }
      expect(ping.isMotifServer, isTrue, reason: 'service=${ping.service}');

      final list = await rpc.call('session.list');
      final sessions = (list['sessions'] as List?) ?? [];
      if (sessions.isEmpty) {
        await rpc.close();
        markTestSkipped('no sessions on the server to attach to');
        return;
      }
      final name = (sessions.first as Map)['name'] as String;

      // Collect events for a short window after attach.
      final received = <String>[];
      final sub = rpc.events.listen((e) => received.add(e.method));

      final attach = await rpc.call('session.attach', {'name': name});
      expect(attach['session'], isNotNull);

      // Activate the first pty (if any) so the /pty stream opens.
      final ptys = (attach['ptys'] as List?) ?? [];
      final ptyId = ptys.isEmpty ? null : (ptys.first as Map)['id'] as String;
      if (ptyId != null) {
        await rpc.activatePty(ptyId);
      }

      // Wait for the /pty replay (meta frame + ring) to arrive and parse.
      await Future<void>.delayed(const Duration(seconds: 2));
      await sub.cancel();
      await rpc.close();

      // We should at least have attached cleanly; if there was a pty, we should
      // have seen synthesized pty.output (the ring replay) flow through the
      // shell parser.
      if (ptyId != null) {
        expect(
          received,
          contains('pty.output'),
          reason: 'expected /pty replay; got: ${received.toSet()}',
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  // Full bidirectional loop in a throwaway session (non-intrusive): create
  // session → spawn pty → write a command → confirm the echoed output comes
  // back through /pty → shell parser → pty.output. Cleans up after itself.
  test(
    'write → server → pty.output round-trip (own session)',
    () async {
      final rpc = RpcClient()..connect(host: host, port: port, token: '');
      try {
        await rpc.ping();
      } catch (e) {
        await rpc.close();
        markTestSkipped('no motifd on $host:$port ($e)');
        return;
      }

      final marker = 'MOTIF_RT_${DateTime.now().microsecondsSinceEpoch}';
      final name = 'flutter-rt-${DateTime.now().millisecondsSinceEpoch}';
      final output = StringBuffer();
      final sub = rpc.events.listen((e) {
        if (e.method == 'pty.output') {
          final raw = e.params['data_bytes'];
          final bytes = raw is List<int>
              ? raw
              : base64Decode((e.params['data_b64'] as String?) ?? '');
          if (bytes.isNotEmpty) output.write(String.fromCharCodes(bytes));
        }
      });

      String? ptyId;
      try {
        await rpc.call('session.create', {'name': name, 'workdir': '~'});
        await rpc.call('session.attach', {'name': name});
        final created = await rpc.call('pty.create', {'cols': 80, 'rows': 24});
        ptyId = (created['info'] as Map?)?['id'] as String?;
        expect(ptyId, isNotNull, reason: 'pty.create returned no id');

        await rpc.activatePty(ptyId!);
        // Let the shell come up, then send `echo <marker>`.
        await Future<void>.delayed(const Duration(seconds: 1));
        await rpc.writePty(ptyId, 'echo $marker\n'.codeUnits);

        // Poll up to ~6s for the echoed marker to appear in the output.
        var seen = false;
        for (var i = 0; i < 24; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (output.toString().contains(marker)) {
            seen = true;
            break;
          }
        }
        expect(
          seen,
          isTrue,
          reason: 'expected echoed "$marker" in pty output; got:\n$output',
        );
      } finally {
        await sub.cancel();
        if (ptyId != null) {
          try {
            await rpc.call('pty.kill', {'pty_id': ptyId});
          } catch (_) {}
        }
        try {
          await rpc.call('session.destroy', {'name': name});
        } catch (_) {}
        await rpc.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
