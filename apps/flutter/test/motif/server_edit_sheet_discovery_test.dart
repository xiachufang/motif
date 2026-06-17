import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
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
    const server = MotifServer(
      id: 'srv-rzv',
      name: 'Studio',
      host: 'us.allsunday.io',
      port: 8765,
      scheme: 'https',
      kind: ServerKind.rendezvous,
      relay: 'us.allsunday.io:8765',
      psk: 'AAA',
      pubKey: 'BBB',
    );
    await app.servers.add(server);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: ServerEditSheet(existing: server)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The rendezvous panel: relay + encryption, no host/port/token/segments.
    expect(find.text('Rendezvous Server'), findsOneWidget);
    expect(find.text('us.allsunday.io:8765'), findsOneWidget);
    expect(find.text('End-to-end encrypted (cert pinned)'), findsOneWidget);
    expect(_fieldWithLabel('Host'), findsNothing);
    expect(_fieldWithLabel('Port'), findsNothing);
    expect(find.text('Tailscale'), findsNothing);

    // Saving only updates the name; the kind/relay are never coerced.
    await tester.enterText(_fieldWithLabel('Name'), 'Studio Mac');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = app.servers.servers.single;
    expect(saved.kind, ServerKind.rendezvous);
    expect(saved.name, 'Studio Mac');
    expect(saved.relay, 'us.allsunday.io:8765');
    expect(saved.host, 'us.allsunday.io');
    expect(saved.port, 8765);
  });

  testWidgets('saves an SSH server with password auth', (tester) async {
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

    await tester.tap(find.text('SSH'));
    await tester.pumpAndSettle();
    expect(find.text('SSH LOGIN'), findsOneWidget);
    await tester.enterText(_fieldWithLabel('Name'), 'Bastion');
    await tester.enterText(_fieldWithLabel('SSH Host'), 'bastion.example.com');
    await tester.enterText(_fieldWithLabel('Username'), 'fei');
    await _scrollTo(tester, _fieldWithLabel('SSH Password'));
    await tester.enterText(_fieldWithLabel('SSH Password'), 'secret');
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
  });

  testWidgets('saves an SSH server with private key auth', (tester) async {
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

Finder _serverEditScrollable() => find
    .descendant(
      of: find.byType(ServerEditSheet),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 12; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.drag(_serverEditScrollable(), const Offset(0, -140));
    await tester.pumpAndSettle();
  }
  expect(finder, findsWidgets);
}
