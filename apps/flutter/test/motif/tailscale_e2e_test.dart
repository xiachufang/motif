@Tags(['tailscale_live'])
library;

import 'dart:io';

import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/net/rpc_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Full Tailscale hop: RpcClient → tsnet loopback proxy → tailnet → a tsnet
/// node that forwards to the local motifd. Drive it with the values printed by
/// the tsnet node (see /tmp/tsnode):
///   TS_NODE_IP=100.x.x.x TS_PROXY=127.0.0.1:PORT TS_CRED=... \
///     flutter test test/motif/tailscale_e2e_test.dart --tags tailscale_live
void main() {
  test('ping reaches motifd over the tailnet via the tsnet loopback proxy',
      () async {
    final ip = Platform.environment['TS_NODE_IP'];
    final proxy = Platform.environment['TS_PROXY'];
    final cred = Platform.environment['TS_CRED'];
    if (ip == null || proxy == null) {
      markTestSkipped('need TS_NODE_IP + TS_PROXY (+ TS_CRED) from the tsnet node');
      return;
    }
    final parts = proxy.split(':');
    final rpc = RpcClient()
      ..connect(
        host: ip,
        port: 7777,
        token: '',
        proxy: ProxySettings(
          proxyHost: parts[0],
          proxyPort: int.parse(parts[1]),
          username: 'tsnet', // tsnet loopback requires user "tsnet"
          password: cred, // ...with proxyCred as the password
        ),
      );
    final ping = await rpc.ping();
    expect(ping.isMotifServer, isTrue,
        reason: 'ping should reach motifd over the tailnet');
    await rpc.close();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
