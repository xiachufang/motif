import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/platform/tailscale_ffi.dart';
import 'package:motif/motif/platform/tailscale_native_service.dart';

void main() {
  test('local API status reads auth URL with tsnet auth headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <HttpRequest>[];
    final serve = server.listen((request) {
      requests.add(request);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'BackendState': 'NeedsLogin',
          'AuthURL': 'https://login.tailscale.com/a/abc123',
        }),
      );
      request.response.close();
    });

    final client = TailscaleLocalApiClient(
      loopback: TailscaleLoopback(
        '127.0.0.1:${server.port}',
        'proxy-cred',
        'local-api-cred',
      ),
    );

    final status = await client.status();
    client.close();
    await serve.cancel();
    await server.close(force: true);

    expect(status?.backendState, 'NeedsLogin');
    expect(status?.authUrl, 'https://login.tailscale.com/a/abc123');
    expect(status?.toState().status, TailscaleStatus.needsAuth);
    expect(status?.toState().authUrl, 'https://login.tailscale.com/a/abc123');
    expect(requests, hasLength(1));
    expect(requests.single.uri.path, '/localapi/v0/status');
    expect(requests.single.uri.queryParameters['peers'], 'false');
    expect(requests.single.headers.value('Sec-Tailscale'), 'localapi');
    expect(
      requests.single.headers.value(HttpHeaders.authorizationHeader),
      'Basic ${base64Encode(utf8.encode(':local-api-cred'))}',
    );
  });

  test('local API status parses and sorts discovered peers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <HttpRequest>[];
    final serve = server.listen((request) {
      requests.add(request);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'BackendState': 'Running',
          'Self': {
            'HostName': 'motif-flutter',
            'DNSName': 'motif-flutter.tail.ts.net.',
            'TailscaleIPs': ['100.64.0.10'],
            'Online': true,
          },
          'Peer': {
            'node:other': {
              'HostName': 'laptop',
              'DNSName': 'laptop.tail.ts.net.',
              'TailscaleIPs': ['100.64.0.20'],
              'Online': true,
            },
            'node:motifd': {
              'HostName': 'motifd-dev',
              'DNSName': 'motifd-dev.tail.ts.net.',
              'TailscaleIPs': ['fd7a:115c:a1e0::1', '100.64.0.30'],
              'Online': true,
            },
            'node:offline': {
              'HostName': 'motifd-offline',
              'DNSName': 'motifd-offline.tail.ts.net.',
              'TailscaleIPs': ['100.64.0.40'],
              'Online': false,
            },
          },
        }),
      );
      request.response.close();
    });

    final client = TailscaleLocalApiClient(
      loopback: TailscaleLoopback(
        '127.0.0.1:${server.port}',
        'proxy-cred',
        'local-api-cred',
      ),
    );

    final status = await client.status(peers: true);
    client.close();
    await serve.cancel();
    await server.close(force: true);

    final peers = [...status!.peers]
      ..sort(TailscaleNativeService.compareDiscoveredPeers);
    expect(peers.map((p) => p.hostname), [
      'motifd-dev',
      'laptop',
      'motif-flutter',
      'motifd-offline',
    ]);
    expect(peers.first.primaryIP, '100.64.0.30');
    expect(peers.first.preferredAddress, 'motifd-dev.tail.ts.net');
    expect(peers.first.isLikelyMotifd, isTrue);
    expect(requests.single.uri.query, isEmpty);
  });

  test('local API state maps running differently for startup and health', () {
    const status = TailscaleLocalStatus(backendState: 'Running');

    expect(status.toState().status, TailscaleStatus.starting);
    expect(status.toHealthState().status, TailscaleStatus.running);
  });

  test('local API health state degrades when backend stops', () {
    const status = TailscaleLocalStatus(backendState: 'Stopped');
    final state = status.toHealthState();

    expect(state.status, TailscaleStatus.degraded);
    expect(state.detail, 'Tailscale disconnected.');
  });
}
