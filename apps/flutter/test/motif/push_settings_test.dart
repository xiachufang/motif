import 'dart:convert';

import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/platform/push_crypto.dart';
import 'package:motif/motif/platform/secret_store.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('generates a persistent 256-bit AES key', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecretStore();
    final s1 = await PushSettingsStore.load(prefs, secrets);
    expect(base64Decode(s1.encKeyBase64).length, 32);
    final s2 = await PushSettingsStore.load(prefs, secrets);
    expect(s2.encKeyBase64, s1.encKeyBase64);
  });

  test('mute set persists and round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final s = PushSettingsStore(prefs);
    expect(s.enabled, isTrue);
    expect(s.isMuted('work'), isFalse);
    await s.setMuted('work', true);
    expect(s.isMuted('work'), isTrue);

    final reloaded = PushSettingsStore(prefs);
    expect(reloaded.isMuted('work'), isTrue);

    await s.setEnabled(false);
    expect(PushSettingsStore(prefs).enabled, isFalse);
  });

  test('instance-to-server routing persists and prunes', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = PushSettingsStore(prefs);

    await store.bindInstanceToServer('instance-1', 's1');
    await store.bindInstanceToServer('instance-2', 's2');

    final reloaded = PushSettingsStore(prefs);
    expect(reloaded.serverIdForInstance('instance-1'), 's1');
    expect(reloaded.serverIdForInstance('instance-2'), 's2');

    await reloaded.retainInstanceServers({'s2'});
    final pruned = PushSettingsStore(prefs);
    expect(pruned.serverIdForInstance('instance-1'), isNull);
    expect(pruned.serverIdForInstance('instance-2'), 's2');
  });

  test('enabling push registers live clients immediately', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"Dev box","host":"127.0.0.1","port":7777,"token":"","kind":"direct"}]',
    });
    final prefs = await SharedPreferences.getInstance();
    final push = PushSettingsStore(prefs);
    final platformPush = _FakePushService();
    final client = _PushMotifClient('instance-1');
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: push,
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: platformPush,
      ),
      clientFactory: (_) => client,
    );
    app.clientForServer('s1');

    await push.setEnabled(false);
    await Future<void>.delayed(Duration.zero);
    expect(client.registeredTokens, isEmpty);

    await push.setEnabled(true);
    await Future<void>.delayed(Duration.zero);

    expect(platformPush.registerCount, 1);
    expect(client.registeredTokens, ['token-1']);
    expect(client.registeredEnvironments, ['sandbox']);

    app.dispose();
  });

  test('push registration follows client live transitions', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"Dev box","host":"127.0.0.1","port":7777,"token":"","kind":"direct"}]',
    });
    final prefs = await SharedPreferences.getInstance();
    final platformPush = _FakePushService();
    final client = _PushMotifClient('instance-1', live: false);
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: platformPush,
      ),
      clientFactory: (_) => client,
    );
    app.clientForServer('s1');

    client.setLive(true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.registeredTokens, ['token-1']);

    client.setLive(false);
    await Future<void>.delayed(Duration.zero);
    client.setLive(true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.registeredTokens, ['token-1', 'token-2']);

    app.dispose();
  });

  test('app resume re-registers currently live clients', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"Dev box","host":"127.0.0.1","port":7777,"token":"","kind":"direct"}]',
    });
    final prefs = await SharedPreferences.getInstance();
    final platformPush = _FakePushService();
    final client = _PushMotifClient('instance-1');
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: platformPush,
      ),
      clientFactory: (_) => client,
    );
    app.clientForServer('s1');

    await app.registerForPush(client: client);
    expect(client.registeredTokens, ['token-1']);

    app.debugHandleAppResumed();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.registeredTokens, ['token-1', 'token-2']);

    app.dispose();
  });

  test('disabling push unregisters known live server tokens', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"Dev box","host":"127.0.0.1","port":7777,"token":"","kind":"direct"}]',
    });
    final prefs = await SharedPreferences.getInstance();
    final push = PushSettingsStore(prefs);
    final platformPush = _FakePushService();
    final client = _PushMotifClient('instance-1');
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: push,
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: platformPush,
      ),
      clientFactory: (_) => client,
    );
    app.clientForServer('s1');

    await app.registerForPush(client: client);
    await push.setEnabled(false);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.unregisteredTokens, ['token-1']);
    expect(platformPush.unregisterCount, 1);

    app.dispose();
  });

  test('foreground push routes by motifd instance id', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"One","host":"127.0.0.1","port":7777,"token":"","kind":"direct"},'
          '{"id":"s2","name":"Two","host":"127.0.0.1","port":7778,"token":"","kind":"direct"}]',
    });
    final prefs = await SharedPreferences.getInstance();
    final push = PushSettingsStore(prefs);
    final platformPush = _FakePushService();
    final clients = {
      's1': _PushMotifClient('instance-1'),
      's2': _PushMotifClient('instance-2'),
    };
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: push,
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: platformPush,
      ),
      clientFactory: (server) => clients[server.id]!,
    );
    app.clientForServer('s1');
    app.clientForServer('s2');

    await app.registerForPush(client: clients['s1']);
    await app.registerForPush(client: clients['s2']);

    final encrypted = await encryptPushPayload(
      encKeyB64: push.encKeyBase64,
      plaintext: utf8.encode(
        jsonEncode({
          'title': 'Ready',
          'body': 'Build finished',
          'motif': {
            'instance_id': 'instance-2',
            'session_id': 'work',
            'kind': 'finished',
          },
        }),
      ),
    );
    await platformPush.emitEncrypted(encrypted.e, encrypted.n);

    expect(clients['s1']!.latestNotification, isNull);
    expect(clients['s2']!.latestNotification?.title, 'Ready');
    expect(clients['s2']!.latestNotification?.sessionId, 'work');
    expect(clients['s2']!.latestNotification?.kind, 'finished');

    app.dispose();
  });

  test('system notification open routes by instance id', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"One","host":"127.0.0.1","port":7777,"token":"","kind":"direct"},'
          '{"id":"s2","name":"Two","host":"127.0.0.1","port":7778,"token":"","kind":"direct"}]',
      'activeServerID': 's1',
    });
    final prefs = await SharedPreferences.getInstance();
    final push = PushSettingsStore(prefs);
    final platformPush = _FakePushService();
    final clients = {
      's1': _PushMotifClient('instance-1'),
      's2': _PushMotifClient('instance-2'),
    };
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: push,
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: platformPush,
      ),
      clientFactory: (server) => clients[server.id]!,
    );
    app.clientForServer('s1');
    app.clientForServer('s2');
    await app.registerForPush(client: clients['s1']);
    await app.registerForPush(client: clients['s2']);

    platformPush.emitNotificationOpen(
      session: 'work',
      instanceId: 'instance-2',
    );

    expect(app.pendingSessionOpen?.serverId, 's2');
    expect(app.pendingSessionOpen?.session, 'work');
    app.dispose();
  });

  test('system notification open falls back to active server', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"One","host":"127.0.0.1","port":7777,"token":"","kind":"direct"}]',
      'activeServerID': 's1',
    });
    final prefs = await SharedPreferences.getInstance();
    final platformPush = _FakePushService();
    final client = _PushMotifClient('instance-1');
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: platformPush,
      ),
      clientFactory: (_) => client,
    );
    app.clientForServer('s1');

    platformPush.emitNotificationOpen(session: 'nightly');

    expect(app.pendingSessionOpen?.serverId, 's1');
    expect(app.pendingSessionOpen?.session, 'nightly');
    app.dispose();
  });

  test(
    'cold-start pending notification open is drained on AppState init',
    () async {
      SharedPreferences.setMockInitialValues({
        'motif.servers.v1':
            '[{"id":"s1","name":"One","host":"127.0.0.1","port":7777,"token":"","kind":"direct"}]',
        'activeServerID': 's1',
      });
      final prefs = await SharedPreferences.getInstance();
      final platformPush = _FakePushService()
        ..pendingOpen = (session: 'boot-session', instanceId: null);
      final client = _PushMotifClient('instance-1');
      final app = AppState(
        servers: ServerStore(prefs),
        terminalSettings: TerminalSettingsStore(prefs),
        commands: QuickCommandStore(prefs),
        push: PushSettingsStore(prefs),
        platform: PlatformServices(
          tailscale: NoopTailscaleService(),
          speech: NoopSpeechService(),
          push: platformPush,
        ),
        clientFactory: (_) => client,
      );
      app.clientForServer('s1');
      await Future<void>.delayed(Duration.zero);

      expect(app.pendingSessionOpen?.serverId, 's1');
      expect(app.pendingSessionOpen?.session, 'boot-session');
      expect(platformPush.pendingOpen, isNull);
      app.dispose();
    },
  );

  test('cold-start notification uses persisted instance routing', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"One","host":"127.0.0.1","port":7777,"token":"","kind":"direct"},'
          '{"id":"s2","name":"Two","host":"127.0.0.1","port":7778,"token":"","kind":"direct"}]',
      'activeServerID': 's1',
    });
    final prefs = await SharedPreferences.getInstance();
    await PushSettingsStore(prefs).bindInstanceToServer('instance-2', 's2');
    final platformPush = _FakePushService()
      ..pendingOpen = (session: 'nightly', instanceId: 'instance-2');
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: platformPush,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(app.pendingSessionOpen?.serverId, 's2');
    expect(app.pendingSessionOpen?.session, 'nightly');
    app.dispose();
  });

  test('unknown attributed notification does not use the active server', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"One","host":"127.0.0.1","port":7777,"token":"","kind":"direct"},'
          '{"id":"s2","name":"Two","host":"127.0.0.1","port":7778,"token":"","kind":"direct"}]',
      'activeServerID': 's1',
    });
    final prefs = await SharedPreferences.getInstance();
    final platformPush = _FakePushService();
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: platformPush,
      ),
    );

    platformPush.emitNotificationOpen(
      session: 'nightly',
      instanceId: 'unknown-instance',
    );

    expect(app.pendingSessionOpen, isNull);
    app.dispose();
  });
}

class _FakePushService implements PushService {
  int registerCount = 0;
  int unregisterCount = 0;
  void Function(String e, String n)? _handler;
  void Function({required String? session, String? instanceId})? _openHandler;
  ({String? session, String? instanceId})? pendingOpen;

  @override
  bool get isSupported => true;

  @override
  Future<PushRegistration?> register({required String encKeyBase64}) async {
    registerCount += 1;
    return PushRegistration(
      deviceToken: 'token-$registerCount',
      platform: 'ios',
      encKeyBase64: encKeyBase64,
      environment: 'sandbox',
    );
  }

  @override
  Future<void> unregister() async {
    unregisterCount += 1;
  }

  @override
  void onEncryptedPayload(void Function(String e, String n) handler) {
    _handler = handler;
  }

  @override
  void onNotificationOpen(
    void Function({required String? session, String? instanceId}) handler,
  ) {
    _openHandler = handler;
  }

  @override
  Future<({String? session, String? instanceId})?>
  takePendingNotificationOpen() async {
    final pending = pendingOpen;
    pendingOpen = null;
    return pending;
  }

  Future<void> emitEncrypted(String e, String n) async {
    _handler?.call(e, n);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  void emitNotificationOpen({String? session, String? instanceId}) {
    _openHandler?.call(session: session, instanceId: instanceId);
  }
}

class _PushMotifClient extends MotifClient {
  final String instanceId;
  final List<String> registeredTokens = [];
  final List<String?> registeredEnvironments = [];
  final List<String> unregisteredTokens = [];
  bool _live;
  MotifConnState _state;

  _PushMotifClient(this.instanceId, {bool live = true})
    : _live = live,
      _state = live ? const ConnConnected() : const ConnDisconnected();

  @override
  MotifConnState get state => _state;

  @override
  bool get isLive => _live;

  void setLive(bool live) {
    _live = live;
    _state = live ? const ConnConnected() : const ConnDisconnected();
    notifyListeners();
  }

  @override
  Future<String?> registerDevice({
    required String deviceToken,
    required String platform,
    required String encKeyBase64,
    String? environment,
    String? appVersion,
    List<String> mutedSessions = const [],
  }) async {
    registeredTokens.add(deviceToken);
    registeredEnvironments.add(environment);
    return instanceId;
  }

  @override
  Future<void> unregisterDevice(String deviceToken) async {
    unregisteredTokens.add(deviceToken);
  }

  @override
  void showNotification(MotifNotification n) {
    latestNotification = n;
  }
}
