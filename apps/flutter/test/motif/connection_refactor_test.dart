import 'dart:typed_data';

import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/net/ssh/ssh_bootstrapper.dart';
import 'package:motif/motif/net/ssh/ssh_forwarder_handle.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/connection/connection_state.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_controller.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_view_model.dart';
import 'package:motif/motif/state/workspace/workspace_lifecycle_controller.dart';
import 'package:motif/motif/state/workspace/workspace_retention_policy.dart';
import 'package:motif/motif/state/server/server_view_models.dart';
import 'package:motif/motif/state/server/server_transport.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/state/server/transport_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_server_transport.dart';
import 'support/workspace_connection_fixture.dart';

class _FakeTailscale extends TailscaleService {
  String resolvedHost;
  ProxySettings? proxy;
  int resolveCalls = 0;

  _FakeTailscale(TailscaleState state, {this.resolvedHost = '', this.proxy})
    : super(initialState: state);

  void emit(TailscaleState state) => tailscaleState = state;

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

  Future<void> close() => Future<void>.value();
}

class _RecordingWorkspaceConnectionController
    extends WorkspaceConnectionController {
  _RecordingWorkspaceConnectionController({super.session = 'dev'});

  int connectCalls = 0;
  int suspendCalls = 0;
  int disconnectCalls = 0;
  final List<bool> connectForces = [];
  int connectFailuresRemaining = 0;

  @override
  Future<void> connect(
    MotifServer server, {
    bool force = false,
    ProxySettings proxy = ProxySettings.none,
    Uint8List? certPin,
  }) async {
    connectCalls++;
    connectForces.add(force);
    if (connectFailuresRemaining > 0) {
      connectFailuresRemaining--;
      throw StateError('motifd unavailable');
    }
    updateConnectionState(ConnAttached(session), live: true);
  }

  void attachSnapshot() {
    ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)];
    views = const [ViewInfo(id: 'view-1', spec: PtyViewSpec('pty-1'))];
    activeViewId = 'view-1';
    updateConnectionState(ConnAttached(session), live: true);
  }

  void failConnection(String message) {
    updateConnectionState(ConnFailed(message), live: false);
  }

  @override
  Future<void> suspendTransport(String reason) async {
    suspendCalls++;
    updateConnectionState(ConnSuspended(reason, session: session), live: false);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    updateConnectionState(const ConnDisconnected(), live: false);
    ptys = [];
    views = [];
    activeViewId = null;
  }
}

class _RecordingServerFixture {
  _RecordingServerFixture({this.refreshFailuresRemaining = 0}) {
    transport = TestServerTransport(
      onConnect:
          (
            transport,
            server, {
            required force,
            required proxy,
            required certPin,
          }) async {
            if (connectFailuresRemaining > 0) {
              connectFailuresRemaining--;
              throw StateError('motifd unavailable');
            }
            return const PingInfo(service: 'motif-server', version: 'test');
          },
      onCall: (method, [params = const {}]) async {
        if (method != 'session.list') return const {};
        refreshCalls++;
        if (refreshFailuresRemaining > 0) {
          refreshFailuresRemaining--;
          throw const ServerTransportException('stale transport');
        }
        return const {'sessions': <Object?>[]};
      },
    );
  }

  late final TestServerTransport transport;
  int refreshFailuresRemaining;
  int refreshCalls = 0;
  int connectFailuresRemaining = 0;

  int get connectCalls => transport.connectCalls;
  List<bool> get connectForces => transport.connectForces;
}

class _FakeSshForwarder implements SshForwarderHandle {
  _FakeSshForwarder({required this.remoteHost, required this.remotePort});

  final String remoteHost;
  final int remotePort;
  final int localPort = 41000;
  int startCalls = 0;
  int stopCalls = 0;
  bool _running = false;

  @override
  int get port => localPort;

  @override
  bool get isRunning => _running;

  @override
  bool matches(SshForwarderHandle other) =>
      other is _FakeSshForwarder &&
      remoteHost == other.remoteHost &&
      remotePort == other.remotePort;

  @override
  Future<int> start() async {
    startCalls++;
    _running = true;
    return localPort;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _running = false;
  }
}

PlatformServices _platform(_FakeTailscale tailscale) => PlatformServices(
  tailscale: tailscale,
  speech: NoopSpeechService(),
  push: NoopPushService(),
);

Future<AppState> _appWith({
  required _FakeTailscale tailscale,
  required _RecordingServerFixture server,
  WorkspaceConnectionController? workspace,
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
    serverTransportFactory: (_) => server.transport,
    workspaceConnectionFactory: workspace == null ? null : (_, _) => workspace,
  );
}

void main() {
  group('TransportResolver', () {
    test('maps Tailscale states to transport view state', () {
      const server = MotifServer(
        id: 'tailnet',
        name: 'Tailnet',
        host: 'motifd.tail.ts.net',
        kind: ServerKind.tailscale,
      );
      final cases = [
        (
          TailscaleState.stopped,
          TransportStatus.setupNeeded,
          TransportAction.setup,
          false,
        ),
        (
          const TailscaleState(TailscaleStatus.needsAuth),
          TransportStatus.setupNeeded,
          TransportAction.setup,
          false,
        ),
        (
          const TailscaleState(TailscaleStatus.starting),
          TransportStatus.starting,
          TransportAction.none,
          true,
        ),
        (
          const TailscaleState(TailscaleStatus.running),
          TransportStatus.ready,
          TransportAction.none,
          false,
        ),
        (
          const TailscaleState(TailscaleStatus.degraded),
          TransportStatus.degraded,
          TransportAction.setup,
          true,
        ),
        (
          const TailscaleState(TailscaleStatus.failed),
          TransportStatus.failed,
          TransportAction.setup,
          false,
        ),
      ];

      for (final entry in cases) {
        final view = TransportViewState.tailscale(server, entry.$1);
        expect(view.status, entry.$2);
        expect(view.action, entry.$3);
        expect(view.showSpinner, entry.$4);
        expect(view.kind, ServerKind.tailscale);
      }
    });

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

    test('blocks SSH servers with incomplete login settings', () async {
      final tailscale = _FakeTailscale(TailscaleState.stopped);
      addTearDown(tailscale.close);
      final resolver = TransportResolver(_platform(tailscale));

      final missingUser = await resolver.resolve(
        const MotifServer(
          id: 'ssh',
          name: 'SSH',
          host: '127.0.0.1',
          kind: ServerKind.ssh,
          sshHost: 'bastion.example.com',
          sshPassword: 'secret',
        ),
      );
      expect(missingUser, isA<TransportBlocked>());
      final missingUserBlocker = (missingUser as TransportBlocked).blocker;
      expect(missingUserBlocker.transport.status, TransportStatus.setupNeeded);
      expect(missingUserBlocker.transport.action, TransportAction.setup);
      expect(missingUserBlocker.message, contains('username'));

      final missingKey = await resolver.resolve(
        const MotifServer(
          id: 'ssh',
          name: 'SSH',
          host: '127.0.0.1',
          kind: ServerKind.ssh,
          sshHost: 'bastion.example.com',
          sshUsername: 'fei',
          sshAuthMethod: SshAuthMethod.privateKey,
        ),
      );
      expect(missingKey, isA<TransportBlocked>());
      final missingKeyBlocker = (missingKey as TransportBlocked).blocker;
      expect(missingKeyBlocker.transport.status, TransportStatus.setupNeeded);
      expect(missingKeyBlocker.transport.action, TransportAction.setup);
      expect(missingKeyBlocker.message, contains('private key'));
    });

    test('auto-initializes SSH motifd before starting the tunnel', () async {
      final tailscale = _FakeTailscale(TailscaleState.stopped);
      addTearDown(tailscale.close);
      final bootstrapped = <MotifServer>[];
      final forwarders = <_FakeSshForwarder>[];
      final resolver = TransportResolver(
        _platform(tailscale),
        sshAutoInitializer: (server) async => bootstrapped.add(server),
        sshForwarderFactory:
            ({
              required sshHost,
              required sshPort,
              required username,
              required authMethod,
              required password,
              required privateKey,
              required privateKeyPassphrase,
              required remoteHost,
              required remotePort,
              required connectTimeout,
            }) {
              final fwd = _FakeSshForwarder(
                remoteHost: remoteHost,
                remotePort: remotePort,
              );
              forwarders.add(fwd);
              return fwd;
            },
      );

      final result = await resolver.resolve(
        const MotifServer(
          id: 'ssh',
          name: 'SSH',
          host: '127.0.0.1',
          port: 7777,
          kind: ServerKind.ssh,
          sshHost: 'bastion.example.com',
          sshUsername: 'fei',
          sshPassword: 'secret',
          sshAutoInitialize: true,
        ),
      );

      expect(bootstrapped, hasLength(1));
      expect(forwarders, hasLength(1));
      expect(forwarders.single.startCalls, 1);
      expect(result, isA<TransportReady>());
      final ready = result as TransportReady;
      expect(ready.target.host, '127.0.0.1');
      expect(ready.target.port, 41000);
    });

    test(
      'reports SSH auto-initialize failures before opening a tunnel',
      () async {
        final tailscale = _FakeTailscale(TailscaleState.stopped);
        addTearDown(tailscale.close);
        var forwarderCreated = false;
        final resolver = TransportResolver(
          _platform(tailscale),
          sshAutoInitializer: (_) async => throw const SshBootstrapException(
            stage: 'running remote bootstrap script',
            message:
                'SSH auto-initialize failed while running remote bootstrap script.\n'
                'SSH: fei@bastion.example.com:22\n'
                'Remote motifd target: 127.0.0.1:7777\n'
                'Auth: password\n'
                'Remote bootstrap script failed before motifd became ready.',
            exitCode: 22,
            stderr: 'latest release has no motifd asset for linux-armv7',
            stdout:
                'checking motifd on 127.0.0.1:7777\n'
                'remote platform: linux-armv7',
          ),
          sshForwarderFactory:
              ({
                required sshHost,
                required sshPort,
                required username,
                required authMethod,
                required password,
                required privateKey,
                required privateKeyPassphrase,
                required remoteHost,
                required remotePort,
                required connectTimeout,
              }) {
                forwarderCreated = true;
                return _FakeSshForwarder(
                  remoteHost: remoteHost,
                  remotePort: remotePort,
                );
              },
        );

        final result = await resolver.resolve(
          const MotifServer(
            id: 'ssh',
            name: 'SSH',
            host: '127.0.0.1',
            port: 7777,
            kind: ServerKind.ssh,
            sshHost: 'bastion.example.com',
            sshUsername: 'fei',
            sshPassword: 'secret',
            sshAutoInitialize: true,
          ),
        );

        expect(forwarderCreated, isFalse);
        expect(result, isA<TransportBlocked>());
        final blocker = (result as TransportBlocked).blocker;
        expect(blocker.transport.statusLabel, 'SSH init failed');
        expect(blocker.message, contains('Exit code: 22'));
        expect(
          blocker.message,
          contains('latest release has no motifd asset for linux-armv7'),
        );
        expect(blocker.message, contains('remote platform: linux-armv7'));
        expect(blocker.message, contains('fei@bastion.example.com:22'));
      },
    );

    test(
      'bootstraps WSL and resolves it as a direct loopback target',
      () async {
        final tailscale = _FakeTailscale(TailscaleState.stopped);
        addTearDown(tailscale.close);
        final bootstrapped = <MotifServer>[];
        final resolver = TransportResolver(
          _platform(tailscale),
          wslSupported: true,
          wslAutoInitializer: (server) async => bootstrapped.add(server),
        );
        const server = MotifServer(
          id: 'wsl',
          name: 'Ubuntu',
          host: 'ignored',
          port: 17777,
          kind: ServerKind.wsl,
          wslDistribution: 'Ubuntu-24.04',
        );

        final result = await resolver.resolve(server);

        expect(bootstrapped, [server]);
        expect(result, isA<TransportReady>());
        final ready = result as TransportReady;
        expect(ready.target.host, '127.0.0.1');
        expect(ready.target.port, 17777);
        expect(ready.target.scheme, 'http');
        expect(ready.proxy, ProxySettings.none);
      },
    );

    test(
      'blocks WSL when bootstrap fails or the platform is unsupported',
      () async {
        final tailscale = _FakeTailscale(TailscaleState.stopped);
        addTearDown(tailscale.close);
        const server = MotifServer(
          id: 'wsl',
          name: 'Ubuntu',
          host: '127.0.0.1',
          kind: ServerKind.wsl,
        );
        final unsupported = TransportResolver(
          _platform(tailscale),
          wslSupported: false,
        );
        expect(
          unsupported.transportViewState(server).status,
          TransportStatus.unavailable,
        );

        final failing = TransportResolver(
          _platform(tailscale),
          wslSupported: true,
          wslAutoInitializer: (_) async => throw StateError('no distribution'),
        );
        final result = await failing.resolve(server);
        expect(result, isA<TransportBlocked>());
        final blocker = (result as TransportBlocked).blocker;
        expect(blocker.transport.statusLabel, 'WSL init failed');
        expect(blocker.message, contains('no distribution'));
      },
    );

    test('blocks rendezvous servers with invalid pairing settings', () async {
      final tailscale = _FakeTailscale(TailscaleState.stopped);
      addTearDown(tailscale.close);
      final resolver = TransportResolver(_platform(tailscale));
      const server = MotifServer(
        id: 'rzv',
        name: 'Rendezvous',
        host: '127.0.0.1',
        kind: ServerKind.rendezvous,
        relay: 'https://not-a-websocket-relay.example',
      );

      final view = resolver.transportViewState(server);
      expect(view.status, TransportStatus.setupNeeded);
      expect(view.action, TransportAction.setup);
      expect(view.message, contains('relay address'));

      final result = await resolver.resolve(server);
      expect(result, isA<TransportBlocked>());
      expect(
        (result as TransportBlocked).blocker.transport.kind,
        ServerKind.rendezvous,
      );
    });

    test('runtime transport failure maps to retry action', () {
      const server = MotifServer(
        id: 'ssh',
        name: 'SSH',
        host: '127.0.0.1',
        kind: ServerKind.ssh,
      );
      final transport = TransportViewState.failure(
        kind: ServerKind.ssh,
        statusLabel: 'SSH failed',
        message: 'SSH tunnel failed to start',
      );

      final view = ServerConnectionViewState.from(
        server: server,
        state: ServerBlocked(ConnectionBlocker.fromTransport(transport)),
        transport: transport,
      );

      expect(view.statusLabel, 'SSH failed');
      expect(view.primaryAction, ServerConnectionAction.retry);
      expect(view.tapAction, ServerConnectionAction.retry);
    });
  });

  test(
    'blocked Tailscale connect does not call ServerTransport.connect',
    () async {
      final tailscale = _FakeTailscale(TailscaleState.stopped);
      addTearDown(tailscale.close);
      final server = _RecordingServerFixture();
      final app = await _appWith(tailscale: tailscale, server: server);
      addTearDown(app.dispose);

      await app.connectServer('tailnet', force: true);

      expect(server.connectCalls, 0);
      expect(app.connectionStateForServer('tailnet'), isA<ServerBlocked>());
      expect(
        app.serverViewState('tailnet').primaryAction,
        ServerConnectionAction.setupTransport,
      );
      final transport = app.transportViewStateForServer('tailnet');
      expect(transport.status, TransportStatus.setupNeeded);
      expect(transport.action, TransportAction.setup);
    },
  );

  test('session data updates notify only their observable property', () async {
    final tailscale = _FakeTailscale(TailscaleState.stopped);
    addTearDown(tailscale.close);
    final client = _RecordingWorkspaceConnectionController();
    final server = _RecordingServerFixture();
    final app = await _appWith(tailscale: tailscale, server: server);
    addTearDown(app.dispose);

    app.serverInstance('tailnet');
    var notifications = 0;
    final subscription = observe(
      () => client.presence.latestNotification,
      onChange: (_) => notifications++,
      scheduler: ObservationSchedulers.immediate,
    );
    addTearDown(subscription.dispose);

    client.presence.latestNotification = const MotifNotification(
      title: 'Build complete',
      body: 'Ready',
      kind: 'test',
    );

    expect(notifications, 1);
    expect(app.connectionStateForServer('tailnet'), isA<ServerIdle>());
  });

  test('dynamic workspace membership is observed directly', () async {
    final tailscale = _FakeTailscale(TailscaleState.stopped);
    addTearDown(tailscale.close);
    final server = _RecordingServerFixture();
    final app = await _appWith(tailscale: tailscale, server: server);
    addTearDown(app.dispose);

    var changes = 0;
    final subscription = observe(
      () => app
          .serverRegistryViewModel
          .entries['tailnet']!
          .workspaces
          .retained
          .length,
      onChange: (_) => changes++,
      scheduler: ObservationSchedulers.immediate,
    );
    addTearDown(subscription.dispose);

    app.workspaceForSession('tailnet', 'dev');

    expect(changes, 1);
    expect(app.existingWorkspace('tailnet', 'dev'), isNotNull);
  });

  test(
    'runtime connection state ignores unrelated and projection-only writes',
    () async {
      final tailscale = _FakeTailscale(TailscaleState.stopped);
      addTearDown(tailscale.close);
      final client = _RecordingWorkspaceConnectionController();
      final server = _RecordingServerFixture();
      final app = await _appWith(tailscale: tailscale, server: server);
      addTearDown(app.dispose);
      app.serverInstance('tailnet');

      var changes = 0;
      final subscription = observe(
        () => app.connectionStateForServer('tailnet'),
        onChange: (_) => changes++,
        scheduler: ObservationSchedulers.immediate,
      );
      addTearDown(subscription.dispose);

      client.ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)];
      expect(changes, 0);

      observationTransaction(() {
        app.serverRegistryViewModel.entries['tailnet']!.access
          ..phase = ServerAccessPhase.failed
          ..error = 'offline';
      });
      expect(changes, 0);
      expect(app.connectionStateForServer('tailnet'), isA<ServerIdle>());
    },
  );

  test('Tailscale state is observed without a stream bridge', () {
    final tailscale = _FakeTailscale(TailscaleState.stopped);
    addTearDown(tailscale.close);
    var changes = 0;
    final subscription = observe(
      () => tailscale.state,
      onChange: (_) => changes++,
      scheduler: ObservationSchedulers.immediate,
    );
    addTearDown(subscription.dispose);

    tailscale.emit(const TailscaleState(TailscaleStatus.running));

    expect(changes, 1);
    expect(tailscale.state.status, TailscaleStatus.running);
  });

  test('Tailscale resumes a suspended attached terminal', () async {
    final tailscale = _FakeTailscale(
      const TailscaleState(TailscaleStatus.running),
    );
    addTearDown(tailscale.close);
    final client = _RecordingWorkspaceConnectionController();
    client.attachSnapshot();
    final controller = WorkspaceLifecycleController(
      serverId: 'tailnet',
      connection: client,
      serverProvider: () => const MotifServer(
        id: 'tailnet',
        name: 'Tailnet',
        host: 'motifd.tail.ts.net',
        kind: ServerKind.tailscale,
      ),
      resolver: TransportResolver(_platform(tailscale)),
    );
    final subscription = observe(
      () => client.state,
      onChange: (_) => controller.handleConnectionStateChanged(),
      scheduler: ObservationSchedulers.immediate,
    );
    addTearDown(() {
      subscription.dispose();
      controller.dispose();
    });
    await controller.connect(force: true);
    expect(client.connection.phase, WorkspaceConnectionPhase.attached);

    tailscale.emit(TailscaleState.stopped);
    controller.handleTailscaleState(tailscale.state);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.suspendCalls, 1);
    expect(client.session, 'dev');
    expect(client.views, isNotEmpty);
    expect(client.connection.phase, WorkspaceConnectionPhase.suspended);
    expect(client.connection.blocker, isNotNull);

    tailscale.emit(const TailscaleState(TailscaleStatus.running));
    controller.handleTailscaleState(tailscale.state);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // One explicit initial connect plus one reconnect after Tailscale resumes.
    expect(client.connectCalls, 2);
    expect(client.connection.phase, WorkspaceConnectionPhase.attached);
  });

  test(
    'connection loss shows failed while waiting for reconnect retry',
    () async {
      final tailscale = _FakeTailscale(
        const TailscaleState(TailscaleStatus.running),
      );
      addTearDown(tailscale.close);
      final client = _RecordingWorkspaceConnectionController();
      final resolver = TransportResolver(_platform(tailscale));
      final controller = WorkspaceLifecycleController(
        serverId: 'tailnet',
        connection: client,
        serverProvider: () => const MotifServer(
          id: 'tailnet',
          name: 'Tailnet',
          host: 'motifd.tail.ts.net',
          kind: ServerKind.tailscale,
        ),
        resolver: resolver,
      );
      final subscription = observe(
        () => client.state,
        onChange: (_) => controller.handleConnectionStateChanged(),
        scheduler: ObservationSchedulers.immediate,
      );
      addTearDown(() {
        subscription.dispose();
        controller.dispose();
      });

      await controller.connect(force: true);
      expect(client.connection.phase, WorkspaceConnectionPhase.attached);

      client.failConnection('connection lost');
      await Future<void>.delayed(Duration.zero);

      expect(client.connection.phase, WorkspaceConnectionPhase.failed);
      expect(client.connection.message, 'connection lost');
      final state = ServerFailed(client.connection.message!);
      final view = ServerConnectionViewState.from(
        server: const MotifServer(
          id: 'tailnet',
          name: 'Tailnet',
          host: 'motifd.tail.ts.net',
          kind: ServerKind.tailscale,
        ),
        state: state,
        transport: resolver.transportViewState(
          const MotifServer(
            id: 'tailnet',
            name: 'Tailnet',
            host: 'motifd.tail.ts.net',
            kind: ServerKind.tailscale,
          ),
        ),
      );
      expect(view.statusLabel, 'Failed');
      expect(view.showSpinner, isFalse);
    },
  );

  test(
    'initial session refresh transport failure reconnects and resynchronizes',
    () async {
      final tailscale = _FakeTailscale(
        const TailscaleState(TailscaleStatus.running),
      );
      addTearDown(tailscale.close);
      final server = _RecordingServerFixture(refreshFailuresRemaining: 1);
      final app = await _appWith(tailscale: tailscale, server: server);
      addTearDown(app.dispose);

      await app.connectServer('tailnet', force: true);
      expect(server.connectCalls, 1);

      await Future<void>.delayed(const Duration(milliseconds: 600));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(server.refreshCalls, 2);
      expect(server.connectCalls, 2);
      expect(server.connectForces.last, isTrue);
      expect(app.connectionStateForServer('tailnet'), isA<ServerConnected>());
    },
  );

  test('forced reconnect rebuilds SSH forwarder', () async {
    final tailscale = _FakeTailscale(TailscaleState.stopped);
    addTearDown(tailscale.close);
    final client = _RecordingWorkspaceConnectionController();
    final forwarders = <_FakeSshForwarder>[];
    final resolver = TransportResolver(
      _platform(tailscale),
      sshForwarderFactory:
          ({
            required sshHost,
            required sshPort,
            required username,
            required authMethod,
            required password,
            required privateKey,
            required privateKeyPassphrase,
            required remoteHost,
            required remotePort,
            required connectTimeout,
          }) {
            final fwd = _FakeSshForwarder(
              remoteHost: remoteHost,
              remotePort: remotePort,
            );
            forwarders.add(fwd);
            return fwd;
          },
    );
    final controller = WorkspaceLifecycleController(
      serverId: 'ssh',
      connection: client,
      serverProvider: () => const MotifServer(
        id: 'ssh',
        name: 'SSH',
        host: '127.0.0.1',
        port: 7777,
        kind: ServerKind.ssh,
        sshHost: 'bastion.example.com',
        sshUsername: 'fei',
        sshPassword: 'secret',
      ),
      resolver: resolver,
    );
    final clientSubscription = observe(
      () => client.state,
      onChange: (_) => controller.handleConnectionStateChanged(),
      scheduler: ObservationSchedulers.immediate,
    );
    addTearDown(() {
      clientSubscription.dispose();
      controller.dispose();
    });

    await controller.connect(force: true);
    expect(client.connectCalls, 1);
    expect(forwarders, hasLength(1));
    expect(forwarders.single.startCalls, 1);

    controller.handleTransportFailure(StateError('stale tunnel'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.connectCalls, 2);
    expect(forwarders, hasLength(2));
    expect(forwarders.first.stopCalls, 1);
    expect(forwarders.last.startCalls, 1);
    expect(client.connection.phase, WorkspaceConnectionPhase.attached);
  });

  test(
    'mobile app resume reconnects attached session to rebuild websocket transport',
    () async {
      final tailscale = _FakeTailscale(
        const TailscaleState(TailscaleStatus.running),
      );
      addTearDown(tailscale.close);
      final client = _RecordingWorkspaceConnectionController();
      final controller = WorkspaceLifecycleController(
        serverId: 'tailnet',
        connection: client,
        serverProvider: () => const MotifServer(
          id: 'tailnet',
          name: 'Tailnet',
          host: 'motifd.tail.ts.net',
          kind: ServerKind.tailscale,
        ),
        resolver: TransportResolver(_platform(tailscale)),
      );
      final clientSubscription = observe(
        () => client.state,
        onChange: (_) => controller.handleConnectionStateChanged(),
        scheduler: ObservationSchedulers.immediate,
      );
      addTearDown(() {
        clientSubscription.dispose();
        controller.dispose();
      });

      await controller.connect(force: true);
      expect(client.connectCalls, 1);
      expect(client.isForeground, isTrue);

      controller.handleAppPaused();
      expect(client.isForeground, isFalse);

      controller.handleAppResumed();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(client.isForeground, isTrue);
      expect(client.connectCalls, 2);
      expect(client.connectForces.last, isTrue);
      expect(client.connection.phase, WorkspaceConnectionPhase.attached);
    },
  );

  test(
    'desktop app pause and resume keep attached transport connected',
    () async {
      final tailscale = _FakeTailscale(
        const TailscaleState(TailscaleStatus.running),
      );
      addTearDown(tailscale.close);
      final client = _RecordingWorkspaceConnectionController();
      final controller = WorkspaceLifecycleController(
        serverId: 'tailnet',
        connection: client,
        serverProvider: () => const MotifServer(
          id: 'tailnet',
          name: 'Tailnet',
          host: 'motifd.tail.ts.net',
          kind: ServerKind.tailscale,
        ),
        resolver: TransportResolver(_platform(tailscale)),
        retentionPolicy: const DesktopWorkspaceRetentionPolicy(),
      );
      final clientSubscription = observe(
        () => client.state,
        onChange: (_) => controller.handleConnectionStateChanged(),
        scheduler: ObservationSchedulers.immediate,
      );
      addTearDown(() {
        clientSubscription.dispose();
        controller.dispose();
      });

      await controller.connect(force: true);
      expect(client.connectCalls, 1);
      expect(client.isForeground, isTrue);

      controller.handleAppPaused();
      expect(client.isForeground, isTrue);

      controller.handleAppResumed();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(client.isForeground, isTrue);
      expect(client.connectCalls, 1);
      expect(client.connection.phase, WorkspaceConnectionPhase.attached);
    },
  );

  test(
    'app resume retries server failure after pause canceled backoff',
    () async {
      final tailscale = _FakeTailscale(
        const TailscaleState(TailscaleStatus.running),
      );
      addTearDown(tailscale.close);
      final client = _RecordingWorkspaceConnectionController()
        ..connectFailuresRemaining = 1;
      final controller = WorkspaceLifecycleController(
        serverId: 'tailnet',
        connection: client,
        serverProvider: () => const MotifServer(
          id: 'tailnet',
          name: 'Tailnet',
          host: 'motifd.tail.ts.net',
          kind: ServerKind.tailscale,
        ),
        resolver: TransportResolver(_platform(tailscale)),
      );
      final clientSubscription = observe(
        () => client.state,
        onChange: (_) => controller.handleConnectionStateChanged(),
        scheduler: ObservationSchedulers.immediate,
      );
      addTearDown(() {
        clientSubscription.dispose();
        controller.dispose();
      });

      await controller.connect(force: true);
      expect(client.connectCalls, 1);
      expect(client.connection.phase, WorkspaceConnectionPhase.failed);

      controller.handleAppPaused();
      controller.handleAppResumed();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(client.connectCalls, 2);
      expect(client.connectForces.last, isTrue);
      expect(client.connection.phase, WorkspaceConnectionPhase.attached);
    },
  );

  test(
    'WorkspaceConnectionController.suspendTransport preserves terminal snapshot',
    () async {
      final motif = WorkspaceConnectionController(session: 'dev');
      motif.ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)];
      motif.views = const [ViewInfo(id: 'view-1', spec: PtyViewSpec('pty-1'))];
      motif.activeViewId = 'view-1';

      await motif.suspendTransport('Tailscale disconnected');

      expect(motif.state, isA<ConnSuspended>());
      expect(motif.terminal.canInput, isFalse);
      expect(motif.session, 'dev');
      expect(motif.ptys, isNotEmpty);
      expect(motif.views, isNotEmpty);
      expect(motif.activeViewId, 'view-1');

      await motif.disconnect();

      expect(motif.state, isA<ConnDisconnected>());
      expect(motif.session, 'dev');
      expect(motif.ptys, isEmpty);
      expect(motif.views, isEmpty);
    },
  );
}
