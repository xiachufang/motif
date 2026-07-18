import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/net/ssh/ssh_config_discovery.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:motif/motif/ui/screens/server_edit_sheet.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DiscoveryTailscale implements TailscaleService {
  final TailscaleState _state;

  const _DiscoveryTailscale([
    this._state = const TailscaleState(TailscaleStatus.running),
  ]);

  @override
  TailscaleState get state => _state;

  @override
  Stream<TailscaleState> get states => const Stream.empty();

  @override
  Future<void> start({String? authKey}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<String> resolveHost(String host) async => host;

  @override
  Future<List<TailscalePeer>> discoverPeers() async => const [
    TailscalePeer(
      hostname: 'motifd-dev',
      dnsName: 'motifd-dev.tail.ts.net.',
      primaryIP: '100.64.0.30',
      isLikelyMotifd: true,
      isOnline: true,
    ),
    TailscalePeer(
      hostname: 'laptop',
      dnsName: 'laptop.tail.ts.net.',
      primaryIP: '100.64.0.20',
      isLikelyMotifd: false,
      isOnline: true,
    ),
  ];

  @override
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async => host.startsWith('motifd-dev')
      ? const TailscalePingResult.reachable('test-version')
      : const TailscalePingResult.unreachable('Not motifd');

  @override
  ProxySettings? get loopbackProxy => null;
}

Future<AppState> _app({TailscaleService? tailscale}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices(
      tailscale: tailscale ?? const _DiscoveryTailscale(),
      speech: NoopSpeechService(),
      push: NoopPushService(),
    ),
  );
}

Future<SshConfigSnapshot> _emptySshConfig() async =>
    const SshConfigSnapshot(hosts: [], identities: []);

const _fixturePrivateKey = '''
-----BEGIN OPENSSH PRIVATE KEY-----
fixture
-----END OPENSSH PRIVATE KEY-----
''';

Future<SshConfigSnapshot> _fixtureSshConfig() async => const SshConfigSnapshot(
  hosts: [
    SshConfigHost(
      alias: 'devbox',
      hostName: 'devbox.example.com',
      user: 'fei',
      port: 2222,
      identityFile: '/Users/fei/.ssh/id_ed25519',
    ),
  ],
  identities: [
    SshIdentity(
      path: '/Users/fei/.ssh/id_ed25519',
      name: 'id_ed25519',
      contents: _fixturePrivateKey,
    ),
  ],
);

void main() {
  testWidgets('discovers Tailscale peers and saves a selected motifd server', (
    tester,
  ) async {
    if (kIsWeb) return;

    final app = await _app();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: ServerEditSheet()),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('DISCOVERED ON TAILNET'), findsOneWidget);
    expect(find.text('motifd-dev'), findsOneWidget);
    expect(find.text('motifd-dev.tail.ts.net'), findsOneWidget);
    expect(find.text('Reachable'), findsOneWidget);
    expect(find.text('laptop'), findsNothing);

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(find.text('laptop'), findsOneWidget);

    await tester.tap(find.text('motifd-dev'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(app.servers.servers, hasLength(1));
    final server = app.servers.servers.single;
    expect(server.name, 'motifd-dev');
    expect(server.host, 'motifd-dev.tail.ts.net');
    expect(server.port, 7777);
    expect(server.kind, ServerKind.tailscale);
  });

  testWidgets('Tailscale discovery offers setup when Tailscale is stopped', (
    tester,
  ) async {
    if (kIsWeb) return;

    final app = await _app(
      tailscale: _DiscoveryTailscale(TailscaleState.stopped),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: ServerEditSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('DISCOVERED ON TAILNET'), findsOneWidget);
    expect(find.text('Tailscale is not connected'), findsOneWidget);
    expect(find.text('motifd-dev'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('tailscale-setup-from-server-edit')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Setup Tailscale'), findsOneWidget);
    expect(find.text('Connect with browser'), findsOneWidget);

    Navigator.of(tester.element(find.text('Setup Tailscale'))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('rendezvous server shows a safe read-only panel, not the form', (
    tester,
  ) async {
    if (kIsWeb) return;

    final app = await _app();
    final psk = _base64Key(3);
    final pubKey = _base64Key(4);
    final server = MotifServer(
      id: 'srv-rzv',
      name: 'Studio',
      host: 'us.allsunday.io',
      port: 8765,
      scheme: 'https',
      kind: ServerKind.rendezvous,
      relay: 'us.allsunday.io:8765',
      psk: psk,
      pubKey: pubKey,
    );
    await app.servers.add(server);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Scaffold(body: ServerEditSheet(existing: server)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The rendezvous panel: relay + encryption, no host/port/token/segments.
    expect(find.text('Rendezvous Server'), findsOneWidget);
    expect(find.text('us.allsunday.io:8765'), findsOneWidget);
    expect(find.text('End-to-end encrypted (cert pinned)'), findsOneWidget);
    expect(_fieldWithLabel('Relay'), findsOneWidget);
    expect(_fieldWithLabel('Pairing Secret (psk)'), findsOneWidget);
    expect(_fieldWithLabel('Certificate Pin (pubKey)'), findsOneWidget);
    expect(_fieldWithLabel('Host'), findsNothing);
    expect(_fieldWithLabel('Port'), findsNothing);
    expect(find.text('Tailscale'), findsNothing);

    // Saving keeps the rendezvous kind while preserving editable pairing data.
    await tester.enterText(_fieldWithLabel('Name'), 'Studio Mac');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = app.servers.servers.single;
    expect(saved.kind, ServerKind.rendezvous);
    expect(saved.name, 'Studio Mac');
    expect(saved.relay, 'us.allsunday.io:8765');
    expect(saved.host, 'us.allsunday.io');
    expect(saved.port, 8765);
    expect(saved.psk, psk);
    expect(saved.pubKey, pubKey);
  });

  testWidgets('editing rendezvous pairing fields updates relay and keys', (
    tester,
  ) async {
    if (kIsWeb) return;

    final app = await _app();
    final server = MotifServer(
      id: 'srv-rzv',
      name: 'Studio',
      host: 'us.allsunday.io',
      port: 8765,
      scheme: 'https',
      kind: ServerKind.rendezvous,
      relay: 'us.allsunday.io:8765',
      psk: _base64Key(3),
      pubKey: _base64Key(4),
    );
    final nextPsk = _base64Key(13);
    final nextPubKey = _base64Key(14);
    await app.servers.add(server);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Scaffold(body: ServerEditSheet(existing: server)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(_fieldWithLabel('Relay'), 'eu.allsunday.io:9999');
    await tester.enterText(_fieldWithLabel('Pairing Secret (psk)'), nextPsk);
    await tester.enterText(
      _fieldWithLabel('Certificate Pin (pubKey)'),
      nextPubKey,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = app.servers.servers.single;
    expect(saved.kind, ServerKind.rendezvous);
    expect(saved.relay, 'eu.allsunday.io:9999');
    expect(saved.host, 'eu.allsunday.io');
    expect(saved.port, 9999);
    expect(saved.psk, nextPsk);
    expect(saved.pubKey, nextPubKey);
  });

  testWidgets('editing a paired direct server preserves pairing fields', (
    tester,
  ) async {
    if (kIsWeb) return;

    final app = await _app();
    final paired = _pairedDirectServer();
    await app.servers.add(paired);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Scaffold(body: ServerEditSheet(existing: paired)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(_fieldWithLabel('Name'), 'Studio LAN renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = app.servers.servers.single;
    expect(saved.kind, ServerKind.direct);
    expect(saved.name, 'Studio LAN renamed');
    expect(saved.scheme, 'https');
    expect(saved.psk, paired.psk);
    expect(saved.pubKey, paired.pubKey);
    expect(saved.directHosts, ['192.168.1.9', '10.0.0.4']);
  });

  testWidgets('editing a paired direct server can update pairing fields', (
    tester,
  ) async {
    if (kIsWeb) return;

    final app = await _app();
    final paired = _pairedDirectServer();
    final nextPsk = _base64Key(11);
    final nextPubKey = _base64Key(12);
    await app.servers.add(paired);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Scaffold(body: ServerEditSheet(existing: paired)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, _fieldWithLabel('Pairing Secret (psk)'));
    expect(_fieldValue(tester, 'Pairing Secret (psk)'), paired.psk);
    expect(_fieldValue(tester, 'Certificate Pin (pubKey)'), paired.pubKey);
    expect(_fieldValue(tester, 'Direct Hosts'), '192.168.1.9, 10.0.0.4');

    await tester.enterText(_fieldWithLabel('Pairing Secret (psk)'), nextPsk);
    await tester.enterText(
      _fieldWithLabel('Certificate Pin (pubKey)'),
      nextPubKey,
    );
    await tester.enterText(
      _fieldWithLabel('Direct Hosts'),
      'studio.local\n10.0.0.8',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = app.servers.servers.single;
    expect(saved.psk, nextPsk);
    expect(saved.pubKey, nextPubKey);
    expect(saved.directHosts, ['studio.local', '10.0.0.8']);
  });

  testWidgets('editing a paired direct host updates direct candidates', (
    tester,
  ) async {
    if (kIsWeb) return;

    final app = await _app();
    final paired = _pairedDirectServer();
    await app.servers.add(paired);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Scaffold(body: ServerEditSheet(existing: paired)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(_fieldWithLabel('Host'), 'studio.local');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = app.servers.servers.single;
    expect(saved.host, 'studio.local');
    expect(saved.psk, paired.psk);
    expect(saved.pubKey, paired.pubKey);
    expect(saved.directHosts, ['studio.local']);
  });

  testWidgets('direct cert pin with no candidates uses the host as candidate', (
    tester,
  ) async {
    if (kIsWeb) return;

    final app = await _app();
    final server = MotifServer(
      id: 'srv-manual',
      name: 'Manual',
      host: 'studio.local',
      port: 7777,
      kind: ServerKind.direct,
    );
    final pubKey = _base64Key(15);
    await app.servers.add(server);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Scaffold(body: ServerEditSheet(existing: server)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, _fieldWithLabel('Certificate Pin (pubKey)'));
    expect(_fieldValue(tester, 'Direct Hosts'), isEmpty);
    await tester.enterText(_fieldWithLabel('Certificate Pin (pubKey)'), pubKey);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = app.servers.servers.single;
    expect(saved.scheme, 'https');
    expect(saved.pubKey, pubKey);
    expect(saved.directHosts, ['studio.local']);
  });

  testWidgets('saves an SSH server with password auth', (tester) async {
    if (kIsWeb) return;

    final app = await _app();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Scaffold(
            body: ServerEditSheet(sshConfigDiscoveryLoader: _emptySshConfig),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('SSH'));
    await tester.pumpAndSettle();
    expect(find.text('SSH LOGIN'), findsOneWidget);
    await tester.enterText(_fieldWithLabel('Name'), 'Bastion');
    await tester.enterText(_fieldWithLabel('SSH Host'), 'bastion.example.com');
    await tester.enterText(_fieldWithLabel('Username'), 'fei');
    await _scrollTo(tester, _fieldWithLabel('SSH Password'));
    await tester.enterText(_fieldWithLabel('SSH Password'), 'secret');
    await _scrollTo(tester, find.text('Auto initialize'));
    await tester.drag(_serverEditScrollable(), const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto initialize'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('MOTIFD TARGET'));
    expect(find.text('MOTIFD TARGET'), findsOneWidget);
    await _scrollTo(tester, _fieldWithLabel('Remote Host'));
    await tester.enterText(_fieldWithLabel('Remote Host'), '127.0.0.1');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final server = app.servers.servers.single;
    expect(server.kind, ServerKind.ssh);
    expect(server.host, '127.0.0.1');
    expect(server.port, 7777);
    expect(server.sshHost, 'bastion.example.com');
    expect(server.sshPort, 22);
    expect(server.sshUsername, 'fei');
    expect(server.sshAuthMethod, SshAuthMethod.password);
    expect(server.sshPassword, 'secret');
    expect(server.sshAutoInitialize, isTrue);
  });

  testWidgets('saves an SSH server with private key auth', (tester) async {
    if (kIsWeb) return;

    final app = await _app();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Scaffold(
            body: ServerEditSheet(sshConfigDiscoveryLoader: _emptySshConfig),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('SSH'));
    await tester.pumpAndSettle();
    await tester.enterText(_fieldWithLabel('Name'), 'Key Host');
    await tester.enterText(_fieldWithLabel('SSH Host'), 'key.example.com');
    await tester.enterText(_fieldWithLabel('SSH Port'), '2222');
    await tester.enterText(_fieldWithLabel('Username'), 'deploy');
    await _scrollTo(tester, find.text('Private Key'));
    await tester.tap(find.text('Private Key').first);
    await tester.pumpAndSettle();
    await _scrollTo(tester, _fieldWithLabel('Private Key PEM'));
    await tester.enterText(
      _fieldWithLabel('Private Key PEM'),
      '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----',
    );
    await tester.enterText(_fieldWithLabel('Key Passphrase (optional)'), 'pw');
    await _scrollTo(tester, _fieldWithLabel('Remote Host'));
    await tester.enterText(_fieldWithLabel('Remote Host'), '127.0.0.1');
    await tester.enterText(_fieldWithLabel('Remote Port'), '17777');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final server = app.servers.servers.single;
    expect(server.kind, ServerKind.ssh);
    expect(server.host, '127.0.0.1');
    expect(server.port, 17777);
    expect(server.sshHost, 'key.example.com');
    expect(server.sshPort, 2222);
    expect(server.sshUsername, 'deploy');
    expect(server.sshAuthMethod, SshAuthMethod.privateKey);
    expect(server.sshPrivateKey, contains('OPENSSH PRIVATE KEY'));
    expect(server.sshPrivateKeyPassphrase, 'pw');
    expect(server.sshAutoInitialize, isFalse);
  });

  testWidgets('Windows saves WSL as a bootstrap connection type', (
    tester,
  ) async {
    if (kIsWeb) return;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final app = await _app();
      addTearDown(app.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: MaterialApp(
            theme: motifTheme(Brightness.dark),
            home: const Scaffold(body: ServerEditSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('WSL'), findsWidgets);
      expect(find.text('WSL MOTIFD'), findsOneWidget);
      expect(find.text('SSH LOGIN'), findsNothing);
      await tester.enterText(_fieldWithLabel('Name'), 'Ubuntu Dev');
      await tester.enterText(
        _fieldWithLabel('Distribution (optional)'),
        'Ubuntu-24.04',
      );
      await _scrollTo(tester, _fieldWithLabel('WSL Port'));
      await tester.enterText(_fieldWithLabel('WSL Port'), '17777');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final server = app.servers.servers.single;
      expect(server.kind, ServerKind.wsl);
      expect(server.host, '127.0.0.1');
      expect(server.port, 17777);
      expect(server.wslDistribution, 'Ubuntu-24.04');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('prefills SSH login and key from discovered config', (
    tester,
  ) async {
    if (kIsWeb) return;

    final app = await _app();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Scaffold(
            body: ServerEditSheet(
              initialKind: ServerKind.ssh,
              sshConfigDiscoveryLoader: _fixtureSshConfig,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Choose SSH host'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('devbox').last);
    await tester.pumpAndSettle();

    expect(_fieldValue(tester, 'Name'), 'devbox');
    expect(_fieldValue(tester, 'SSH Host'), 'devbox.example.com');
    expect(_fieldValue(tester, 'SSH Port'), '2222');
    expect(_fieldValue(tester, 'Username'), 'fei');
    await _scrollTo(tester, _fieldWithLabel('Private Key PEM'));
    expect(_fieldValue(tester, 'Private Key PEM'), _fixturePrivateKey);
  });

  testWidgets('web hides Tailscale server options', (tester) async {
    if (!kIsWeb) return;

    final app = await _app();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: ServerEditSheet()),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Reach via'), findsNothing);
    expect(find.text('Tailscale'), findsNothing);
    expect(find.text('DISCOVERED ON TAILNET'), findsNothing);

    await tester.enterText(_fieldWithLabel('Name'), 'Web Dev');
    await tester.enterText(_fieldWithLabel('Host'), '127.0.0.1');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(app.servers.servers, hasLength(1));
    expect(app.servers.servers.single.kind, ServerKind.direct);
  });
}

Finder _fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _fieldValue(WidgetTester tester, String label) {
  final field = tester.widget<TextField>(_fieldWithLabel(label));
  return field.controller?.text ?? '';
}

String _base64Key(int seed) => base64Url
    .encode(Uint8List.fromList(List.generate(32, (i) => seed + i)))
    .replaceAll('=', '');

MotifServer _pairedDirectServer() => MotifServer(
  id: 'srv-direct',
  name: 'Studio LAN',
  host: '192.168.1.9',
  port: 7777,
  scheme: 'https',
  kind: ServerKind.direct,
  psk: _base64Key(1),
  pubKey: _base64Key(2),
  directHosts: const ['192.168.1.9', '10.0.0.4'],
);

Finder _serverEditScrollable() => find
    .descendant(
      of: find.byType(ServerEditSheet),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 12; i++) {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder.first);
      await tester.pumpAndSettle();
      return;
    }
    await tester.drag(_serverEditScrollable(), const Offset(0, -140));
    await tester.pumpAndSettle();
  }
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
}
