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
  @override
  TailscaleState get state => const TailscaleState(TailscaleStatus.running);

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

Future<AppState> _app() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices(
      tailscale: _DiscoveryTailscale(),
      speech: NoopSpeechService(),
      push: NoopPushService(),
    ),
  );
}

void main() {
  testWidgets('discovers Tailscale peers and saves a selected motifd server', (
    tester,
  ) async {
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
}
