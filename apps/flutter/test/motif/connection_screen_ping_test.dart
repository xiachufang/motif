import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/net/rpc_client.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:motif/motif/ui/screens/connection_screen.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PingTailscale implements TailscaleService {
  @override
  final TailscaleState state;
  final Map<String, TailscalePingResult> results;
  final List<String> pingedHosts = [];

  _PingTailscale({required this.state, this.results = const {}});

  @override
  Stream<TailscaleState> get states => const Stream.empty();

  @override
  Future<void> start({String? authKey}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<String> resolveHost(String host) async => host;

  @override
  Future<List<TailscalePeer>> discoverPeers() async => const [];

  @override
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    pingedHosts.add('$host:$port');
    return results[host] ??
        const TailscalePingResult.unreachable('No response');
  }

  @override
  ProxySettings? get loopbackProxy => null;
}

class _MutableTailscale implements TailscaleService {
  TailscaleState _state;
  final StreamController<TailscaleState> _states =
      StreamController<TailscaleState>.broadcast();

  _MutableTailscale(this._state);

  @override
  TailscaleState get state => _state;

  @override
  Stream<TailscaleState> get states => _states.stream;

  void emit(TailscaleState state) {
    _state = state;
    _states.add(state);
  }

  Future<void> close() => _states.close();

  @override
  Future<void> start({String? authKey}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<String> resolveHost(String host) async => host;

  @override
  Future<List<TailscalePeer>> discoverPeers() async => const [];

  @override
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async => const TailscalePingResult.reachable('test');

  @override
  ProxySettings? get loopbackProxy => null;
}

class _ManualMotifClient extends MotifClient {
  MotifConnState _manualState = const ConnDisconnected();
  bool _live = false;
  int refreshes = 0;

  @override
  MotifConnState get state => _manualState;

  @override
  bool get isLive => _live;

  @override
  Future<void> connect(
    MotifServer server, {
    bool force = false,
    ProxySettings proxy = ProxySettings.none,
  }) async {
    _live = true;
    _manualState = const ConnConnected();
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    _live = false;
    _manualState = const ConnDisconnected();
    notifyListeners();
  }

  @override
  Future<void> refreshSessions() async {
    refreshes++;
  }
}

class _FailingMotifClient extends MotifClient {
  int attempts = 0;
  MotifConnState _manualState = const ConnDisconnected();

  @override
  MotifConnState get state => _manualState;

  @override
  bool get isLive => false;

  @override
  Future<void> connect(
    MotifServer server, {
    bool force = false,
    ProxySettings proxy = ProxySettings.none,
  }) async {
    attempts++;
    _manualState = const ConnFailed('No response');
    notifyListeners();
  }
}

Future<AppState> _appWith({
  required TailscaleService tailscale,
  required List<MotifServer> servers,
  MotifClient Function(MotifServer server)? clientFactory,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final app = AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices(
      tailscale: tailscale,
      speech: NoopSpeechService(),
      push: NoopPushService(),
    ),
    clientFactory: clientFactory,
  );
  for (final server in servers) {
    await app.servers.add(server);
  }
  return app;
}

Future<void> _pumpConnectionScreen(WidgetTester tester, AppState app) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: const ConnectionScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsOneWidget);
}

Finder _fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void _mockDirectPing(
  Map<String, Object?> body, {
  List<Map<String, Object?>> sessions = const [],
}) {
  RpcClient.debugHttpClientFactory = () => MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/ping') {
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.method == 'POST' && request.url.path == '/rpc/session.list') {
      return http.Response(
        jsonEncode({'sessions': sessions}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('', 404);
  });
}

void main() {
  tearDown(() {
    RpcClient.debugHttpClientFactory = null;
  });

  testWidgets('shows reachable ping badge for Tailscale servers', (
    tester,
  ) async {
    final tailscale = _PingTailscale(
      state: const TailscaleState(TailscaleStatus.running),
      results: {
        'motifd-dev.tail.ts.net': const TailscalePingResult.reachable('1.2.3'),
      },
    );
    final app = await _appWith(
      tailscale: tailscale,
      servers: const [
        MotifServer(
          id: 'server-1',
          name: 'Dev',
          host: 'motifd-dev.tail.ts.net',
          port: 7777,
          kind: ServerKind.tailscale,
        ),
      ],
    );

    await _pumpConnectionScreen(tester, app);

    expect(find.text('Dev'), findsOneWidget);
    expect(find.text('Reachable'), findsOneWidget);
    expect(tailscale.pingedHosts, ['motifd-dev.tail.ts.net:7777']);
  });

  testWidgets('shows Tailscale off without probing when tsnet is stopped', (
    tester,
  ) async {
    final tailscale = _PingTailscale(state: TailscaleState.stopped);
    final app = await _appWith(
      tailscale: tailscale,
      servers: const [
        MotifServer(
          id: 'server-1',
          name: 'Dev',
          host: 'motifd-dev.tail.ts.net',
          kind: ServerKind.tailscale,
        ),
      ],
    );

    await _pumpConnectionScreen(tester, app);

    expect(find.text('Tailscale off'), findsOneWidget);
    expect(tailscale.pingedHosts, isEmpty);
  });

  testWidgets('shows reachable ping badge for direct servers', (tester) async {
    _mockDirectPing({'service': 'motif-server', 'version': 'direct-test'});

    final tailscale = _PingTailscale(
      state: const TailscaleState(TailscaleStatus.running),
    );
    final app = await _appWith(
      tailscale: tailscale,
      servers: [
        MotifServer(
          id: 'server-1',
          name: 'Direct',
          host: 'direct.local',
          port: 4567,
          kind: ServerKind.direct,
        ),
      ],
    );

    await _pumpConnectionScreen(tester, app);
    await _pumpUntilFound(tester, find.text('Reachable'));

    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('Reachable'), findsOneWidget);
    expect(tailscale.pingedHosts, isEmpty);
  });

  testWidgets('taps server row to connect and paints connected icon green', (
    tester,
  ) async {
    _mockDirectPing({'service': 'motif-server', 'version': 'direct-test'});

    final manual = _ManualMotifClient();
    final tailscale = _PingTailscale(
      state: const TailscaleState(TailscaleStatus.running),
    );
    final app = await _appWith(
      tailscale: tailscale,
      servers: const [
        MotifServer(
          id: 'server-1',
          name: 'Direct',
          host: 'direct.local',
          port: 4567,
          kind: ServerKind.direct,
        ),
      ],
      clientFactory: (_) => manual,
    );

    await _pumpConnectionScreen(tester, app);

    final icon = find.byKey(const ValueKey('server-kind-icon-server-1'));
    expect(icon, findsOneWidget);
    expect(tester.widget<Icon>(icon).color, MotifColors.dark.textSecondary);
    expect(find.byIcon(Icons.circle), findsNothing);

    await tester.tap(find.text('Direct'));
    await tester.pumpAndSettle();

    expect(app.isServerLive('server-1'), isTrue);
    expect(manual.refreshes, 1);
    expect(tester.widget<Icon>(icon).color, MotifColors.dark.success);
  });

  testWidgets('add server saves and connects in one flow', (tester) async {
    final manual = _ManualMotifClient();
    final tailscale = _PingTailscale(
      state: const TailscaleState(TailscaleStatus.running),
    );
    final app = await _appWith(
      tailscale: tailscale,
      servers: const [],
      clientFactory: (_) => manual,
    );

    await _pumpConnectionScreen(tester, app);

    await tester.tap(find.byTooltip('Add Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct'));
    await tester.pumpAndSettle();
    await tester.enterText(_fieldWithLabel('Name'), 'Direct');
    await tester.enterText(_fieldWithLabel('Host'), 'direct.local');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save and Connect'));
    await tester.pumpAndSettle();

    expect(app.servers.servers, hasLength(1));
    expect(app.servers.servers.single.name, 'Direct');
    expect(app.isServerLive(app.servers.servers.single.id), isTrue);
    expect(manual.refreshes, 1);
  });

  testWidgets('add server can save without connecting', (tester) async {
    final manual = _ManualMotifClient();
    final tailscale = _PingTailscale(
      state: const TailscaleState(TailscaleStatus.running),
    );
    final app = await _appWith(
      tailscale: tailscale,
      servers: const [],
      clientFactory: (_) => manual,
    );

    await _pumpConnectionScreen(tester, app);

    await tester.tap(find.byTooltip('Add Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct'));
    await tester.pumpAndSettle();
    await tester.enterText(_fieldWithLabel('Name'), 'Direct');
    await tester.enterText(_fieldWithLabel('Host'), 'direct.local');
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('save-without-connecting')),
    );
    await tester.tap(find.byKey(const ValueKey('save-without-connecting')));
    await tester.pumpAndSettle();

    expect(app.servers.servers, hasLength(1));
    expect(app.isServerLive(app.servers.servers.single.id), isFalse);
    expect(manual.refreshes, 0);
  });

  testWidgets('connection failures are shown inline and can retry', (
    tester,
  ) async {
    final failing = _FailingMotifClient();
    final tailscale = _PingTailscale(
      state: const TailscaleState(TailscaleStatus.running),
    );
    final app = await _appWith(
      tailscale: tailscale,
      servers: const [
        MotifServer(
          id: 'server-1',
          name: 'Direct',
          host: 'direct.local',
          port: 4567,
          kind: ServerKind.direct,
        ),
      ],
      clientFactory: (_) => failing,
    );

    await _pumpConnectionScreen(tester, app);

    await tester.tap(find.text('Direct'));
    await tester.pumpAndSettle();

    expect(failing.attempts, 1);
    expect(find.textContaining('Failed: No response'), findsOneWidget);

    await tester.tap(find.byTooltip('Retry Connection'));
    await tester.pumpAndSettle();

    expect(failing.attempts, 2);
  });

  testWidgets('connected server row returns to sessions', (tester) async {
    final manual = _ManualMotifClient();
    final tailscale = _PingTailscale(
      state: const TailscaleState(TailscaleStatus.running),
    );
    final app = await _appWith(
      tailscale: tailscale,
      servers: const [
        MotifServer(
          id: 'server-1',
          name: 'Direct',
          host: 'direct.local',
          port: 4567,
          kind: ServerKind.direct,
        ),
      ],
      clientFactory: (_) => manual,
    );
    await app.connectServerAndRefresh('server-1', force: true);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: Text('Sessions home')),
        ),
      ),
    );
    await tester.pump();

    Navigator.of(
      tester.element(find.text('Sessions home')),
    ).push(MaterialPageRoute<void>(builder: (_) => const ConnectionScreen()));
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionScreen), findsOneWidget);

    await tester.tap(find.text('Direct'));
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionScreen), findsNothing);
    expect(find.text('Sessions home'), findsOneWidget);
  });

  testWidgets('shows no ping badge for direct non-motif services', (
    tester,
  ) async {
    _mockDirectPing({'service': 'other-service', 'version': 'direct-test'});

    final tailscale = _PingTailscale(
      state: const TailscaleState(TailscaleStatus.running),
    );
    final app = await _appWith(
      tailscale: tailscale,
      servers: [
        MotifServer(
          id: 'server-1',
          name: 'Direct',
          host: 'direct.local',
          port: 4567,
          kind: ServerKind.direct,
        ),
      ],
    );

    await _pumpConnectionScreen(tester, app);
    await _pumpUntilFound(tester, find.text('No ping'));

    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('No ping'), findsOneWidget);
    expect(tailscale.pingedHosts, isEmpty);
  });

  test('connects and disconnects a direct server manually', () async {
    final manual = _ManualMotifClient();
    final tailscale = _PingTailscale(
      state: const TailscaleState(TailscaleStatus.running),
    );
    final app = await _appWith(
      tailscale: tailscale,
      servers: const [
        MotifServer(
          id: 'server-1',
          name: 'Direct',
          host: 'direct.local',
          port: 4567,
          kind: ServerKind.direct,
        ),
      ],
      clientFactory: (_) => manual,
    );

    await app.connectServer('server-1', force: true);

    expect(app.isServerLive('server-1'), isTrue);

    await app.disconnectServer('server-1');

    expect(app.isServerLive('server-1'), isFalse);
  });

  testWidgets('opens Tailscale setup sheet before connecting tailnet servers', (
    tester,
  ) async {
    final manual = _ManualMotifClient();
    final tailscale = _PingTailscale(state: TailscaleState.stopped);
    final app = await _appWith(
      tailscale: tailscale,
      servers: const [
        MotifServer(
          id: 'server-1',
          name: 'Tailnet',
          host: 'motifd.tail.ts.net',
          kind: ServerKind.tailscale,
        ),
      ],
      clientFactory: (_) => manual,
    );

    await _pumpConnectionScreen(tester, app);
    await tester.tap(find.text('Tailnet'));
    await tester.pumpAndSettle();

    expect(find.text('Connect with browser'), findsOneWidget);
    expect(app.isServerLive('server-1'), isFalse);
  });

  test(
    'disconnects connected Tailscale servers when Tailscale stops',
    () async {
      final tailscale = _MutableTailscale(
        const TailscaleState(TailscaleStatus.running),
      );
      final tailnet = _ManualMotifClient();
      final direct = _ManualMotifClient();
      final app = await _appWith(
        tailscale: tailscale,
        servers: const [
          MotifServer(
            id: 'tailnet',
            name: 'Tailnet',
            host: 'motifd.tail.ts.net',
            kind: ServerKind.tailscale,
          ),
          MotifServer(
            id: 'direct',
            name: 'Direct',
            host: 'direct.local',
            kind: ServerKind.direct,
          ),
        ],
        clientFactory: (server) => server.id == 'tailnet' ? tailnet : direct,
      );
      addTearDown(tailscale.close);

      await app.connectServer('tailnet', force: true);
      await app.connectServer('direct', force: true);

      expect(app.isServerLive('tailnet'), isTrue);
      expect(app.isServerLive('direct'), isTrue);

      tailscale.emit(TailscaleState.stopped);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(app.isServerLive('tailnet'), isFalse);
      expect(app.isServerLive('direct'), isTrue);
    },
  );
}
