@Tags(['tailscale_live'])
library;

import 'dart:io';

import 'package:motif/motif/platform/tailscale_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// Live tunnel bring-up: requires a real tailnet auth key in the env (never
/// hard-coded) and the libtailscale dylib. Run:
///   TS_AUTHKEY=tskey-... flutter test test/motif/tailscale_live_test.dart \
///     --tags tailscale_live
/// Skips if either is missing.
void main() {
  const dylib = '/tmp/libtailscale.dylib';

  test('node comes up and gets a tailnet IP + loopback proxy', () async {
    final key = Platform.environment['TS_AUTHKEY'];
    if (key == null || key.isEmpty || !File(dylib).existsSync()) {
      markTestSkipped('need TS_AUTHKEY env + $dylib');
      return;
    }
    final ts = LibTailscale.open(dylib);
    final sd = ts.create();
    final dir = Directory.systemTemp.createTempSync('motif-tslive-');
    ts.setDir(sd, dir.path);
    ts.setHostname(sd, 'motif-flutter-livetest');
    ts.setAuthkey(sd, key);

    final up = ts.up(sd);
    expect(up, 0, reason: 'tailscale_up should succeed with a valid auth key');

    final ips = ts.getips(sd);
    expect(ips.trim(), isNotEmpty, reason: 'node should receive a tailnet IP');
    // ignore: avoid_print
    print('tailnet IPs: $ips');

    final lb = ts.loopback(sd);
    expect(lb, isNotNull, reason: 'loopback proxy should start');
    // ignore: avoid_print
    print('loopback proxy: ${lb!.proxyAddr}');

    ts.close(sd);
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
