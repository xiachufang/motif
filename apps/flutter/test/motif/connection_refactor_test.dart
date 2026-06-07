import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/connection_state.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:motif/motif/state/transport_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTailscale implements TailscaleService {
  final _controller = StreamController<TailscaleState>.broadcast();
  TailscaleState _state;
  String resolvedHost;
  ProxySettings? proxy;
  int resolveCalls = 0;

  _FakeTailscale(this._state, {this.resolvedHost = '', this.proxy});

  void emit(TailscaleState state) {
    _state = state;
    _controller.add(state);
  }

  @override
  TailscaleState get state => _state;

  @override
  Stream<TailscaleState> get states => _controller.stream;

  @override
  Future<void> start({String? authKey}) async {}

  @override
  Future<void> stop() async => emit(TailscaleState.stopped);

  @override
  Future<String> resolveHost(String host) async {
    resolveCalls++;
    return resolvedHost.isEmpty ? host : resolvedHost;
  }

  @override
  Future<List<TailscalePeer>> discoverPeers() async => const [];

  @override
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async => const TailscalePingResult.unreachable('Tailscale off');

  @override
  ProxySettings? get loopbackProxy => proxy;

  Future<void> close() async => _controller.close();
}

class _RecordingMotifClient extends MotifClient {
  MotifConnState _state = const ConnDisconnected();
  bool _live = false;
  int connectCalls = 0;
  int suspendCalls = 0;
  int disconnectCalls = 0;

  @override
  MotifConnState get state => _state;

  @override
  bool get isLive => _live;

  @override
  Future<void> connect(
    MotifServer server, {
    bool force = false,
    ProxySettings proxy = ProxySettings.none,
  }) async {
    connectCalls++;
    _live = true;
    final session = intendedSession;
    _state = session == null ? const ConnConnected() : ConnAttached(session);
    notifyListeners();
  }

  void attachSnapshot(String session) {
    intendedSession = session;
    ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)];
    views = const [ViewInfo(id: 'view-1', spec: PtyViewSpec('pty-1'))];
    activeViewId = 'view-1';
    _live = true;
    _state = ConnAttached(session);
    notifyListeners();
  }

  void failConnection(String message) {
    _live = false;
    _state = ConnFailed(message);
    notifyListeners();
  }

  @override
  Future<void> suspendTransport(String reason) async {
    suspendCalls++;
    _live = false;
    _state = ConnSuspended(reason, session: intendedSession);
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _live = false;
    _state = const ConnDisconnected();
    intendedSession = null;
    ptys = [];
    views = [];
    activeViewId = null;
    notifyListeners();
  }
}

PlatformServices _platform(_FakeTailscale tailscale) => PlatformServices(
  tailscale: tailscale,
  speech: NoopSpeechService(),
  push: NoopPushService(),
);

Future<AppState> _appWith({
  required _FakeTailscale tailscale,
  required MotifClient client,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final servers = ServerStore(prefs);
  await servers.add(
    const MotifServer(
      id: 'tailnet',
      name: 'Tailnet',
      host: 'motifd.tail.ts.net',
      kind: ServerKind.tailscale,
    ),
  );
  return AppState(
    servers: servers,
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: _platform(tailscale),
    clientFactory: (_) => client,
  );
}

void main() {
  group('TransportResolver', () {
    test('returns direct ready without touching Tailscale', () async {
      final tailscale = _FakeTailscale(TailscaleState.stopped);
      addTearDown(tailscale.close);
      final resolver = TransportResolver(_platform(tailscale));

      final result = await resolver.resolve(
        const MotifServer(id: 'direct', name: 'Direct', host: 'localhost'),
      );

      expect(result, isA<TransportReady>());
      expect((result as TransportReady).target.host, 'localhost');
      expect(result.proxy.isActive, isFalse);
      expect(tailscale.resolveCalls, 0);
    });

    test('blocks Tailscale servers until the backend is running', () async {
      for (final state in const [
        TailscaleState.stopped,
        TailscaleState(TailscaleStatus.starting),
        TailscaleState(TailscaleStatus.needsAuth),
        TailscaleState(TailscaleStatus.degraded),
        TailscaleState(TailscaleStatus.failed),
      ]) {
        final tailscale = _FakeTailscale(state);
        addTearDown(tailscale.close);
        final resolver = TransportResolver(_platform(tailscale));

        final result = await resolver.resolve(
          const MotifServer(
            id: 'tailnet',
            name: 'Tailnet',
            host: 'motifd.tail.ts.net',
            kind: ServerKind.tailscale,
          ),
        );

        expect(result, isA<TransportBlocked>());
      }
    });

    test('resolves host and proxy when Tailscale is running', () async {
      const proxy = ProxySettings(
        proxyHost: '127.0.0.1',
        proxyPort: 41112,
        username: 'tsnet',
        password: 'secret',
      );
      final tailscale = _FakeTailscale(
        const TailscaleState(TailscaleStatus.running),
        resolvedHost: '100.64.0.10',
        proxy: proxy,
      );
      addTearDown(tailscale.close);
      final resolver = TransportResolver(_platform(tailscale));

      final result = await resolver.resolve(
        const MotifServer(
          id: 'tailnet',
          name: 'Tailnet',
          host: 'motifd.tail.ts.net',
          kind: ServerKind.tailscale,
        ),
      );

      expect(result, isA<TransportReady>());
      expect((result as TransportReady).target.host, '100.64.0.10');
      expect(result.proxy, proxy);
    });
  });

  test('blocked Tailscale connect does not call MotifClient.connect', () async {
    final tailscale = _FakeTailscale(TailscaleState.stopped);
    addTearDown(tailscale.close);
    final client = _RecordingMotifClient();
    final app = await _appWith(tailscale: tailscale, client: client);
    addTearDown(app.dispose);

    await app.connectServer('tailnet', force: true);

    expect(client.connectCalls, 0);
    expect(app.connectionStateForServer('tailnet'), isA<ServerBlocked>());
    expect(
      app.serverViewState('tailnet').primaryAction,
      ServerConnectionAction.openTailscale,
    );
  });

  test('Tailscale resumes a suspended attached terminal', () async {
    final tailscale = _FakeTailscale(
      const TailscaleState(TailscaleStatus.running),
    );
    addTearDown(tailscale.close);
    final client = _RecordingMotifClient();
    final app = await _appWith(tailscale: tailscale, client: client);
    addTearDown(app.dispose);

    app.clientForServer('tailnet');
    client.attachSnapshot('dev');
    expect(app.connectionStateForServer('tailnet'), isA<ServerAttached>());

    tailscale.emit(TailscaleState.stopped);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.suspendCalls, 1);
    expect(client.intendedSession, 'dev');
    expect(client.views, isNotEmpty);
    expect(app.connectionStateForServer('tailnet'), isA<ServerSuspended>());

    tailscale.emit(const TailscaleState(TailscaleStatus.running));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.connectCalls, 1);
    expect(app.connectionStateForServer('tailnet'), isA<ServerAttached>());
  });

  test(
    'connection loss shows failed while waiting for reconnect retry',
    () async {
      final tailscale = _FakeTailscale(
        const TailscaleState(TailscaleStatus.running),
      );
      addTearDown(tailscale.close);
      final client = _RecordingMotifClient()..intendedSession = 'dev';
      final app = await _appWith(tailscale: tailscale, client: client);
      addTearDown(app.dispose);

      await app.connectServer('tailnet', force: true);
      expect(app.connectionStateForServer('tailnet'), isA<ServerAttached>());

      client.failConnection('connection lost');
      await Future<void>.delayed(Duration.zero);

      final state = app.connectionStateForServer('tailnet');
      expect(state, isA<ServerFailed>());
      expect((state as ServerFailed).session, 'dev');
      final view = app.serverViewState('tailnet');
      expect(view.statusLabel, 'Failed');
      expect(view.showSpinner, isFalse);
    },
  );

  test('MotifClient.suspendTransport preserves terminal snapshot', () async {
    final motif = MotifClient();
    motif.intendedSession = 'dev';
    motif.ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)];
    motif.views = const [ViewInfo(id: 'view-1', spec: PtyViewSpec('pty-1'))];
    motif.activeViewId = 'view-1';

    await motif.suspendTransport('Tailscale disconnected');

    expect(motif.state, isA<ConnSuspended>());
    expect(motif.canInput, isFalse);
    expect(motif.intendedSession, 'dev');
    expect(motif.ptys, isNotEmpty);
    expect(motif.views, isNotEmpty);
    expect(motif.activeViewId, 'view-1');

    await motif.disconnect();

    expect(motif.state, isA<ConnDisconnected>());
    expect(motif.intendedSession, isNull);
    expect(motif.ptys, isEmpty);
    expect(motif.views, isEmpty);
  });
}
