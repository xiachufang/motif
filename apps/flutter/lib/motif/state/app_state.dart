/// Top-level app state, ported from `apps/ios/Motif/Settings/AppState.swift`.
///
/// Owns the persisted stores and one live [MotifClient] per connected server.
/// Exposed to the widget tree via `provider`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/motif_proto.dart';
import '../models/settings.dart';
import '../net/rzv/pairing_payload.dart';
import '../platform/web_launch.dart';
import '../platform/push_crypto.dart';
import '../platform/services.dart';
import '../terminal/terminal_palette.dart';
import 'connection_state.dart';
import 'embedded_server_service.dart';
import 'embedded_web_server.dart';
import 'motif_client.dart';
import 'motif_runtime.dart';
import 'server_connection_controller.dart';
import 'server_connection_runtime.dart';
import 'stores.dart';
import 'transport_resolver.dart';

/// Desktop top-level view selector: use the client (sessions/terminal) or
/// administer this machine's embedded server.
enum AppViewMode { client, server }

class AppState extends ChangeNotifier {
  final ServerStore servers;
  final TerminalSettingsStore terminalSettings;
  final QuickCommandStore commands;
  final PushSettingsStore push;
  final PlatformServices platform;

  /// Desktop-only embedded motifd (run from the tray). Null on web/mobile or
  /// when the native library isn't bundled.
  final EmbeddedServerService? embeddedServer;
  final String? startupActiveServerId;
  final SessionSidebarUiState sessionSidebar = SessionSidebarUiState();
  final MotifClient Function(MotifServer server) _clientFactory;
  final ServerConnectionRuntime _serverConnectionRuntime;
  late final TransportResolver _transportResolver;
  final Map<String, MotifClient> _clientsByServer = {};
  final Map<String, ServerConnectionController> _controllersByServer = {};
  final Map<String, VoidCallback> _clientListeners = {};
  StreamSubscription<TailscaleState>? _tailscaleSub;
  AppLifecycleListener? _lifecycleListener;

  /// Desktop top-level view: the client (sessions) or the embedded-server
  /// control panel. Only meaningful when [embeddedServer] is available; the UI
  /// shell shows the switch in that case.
  AppViewMode _viewMode = AppViewMode.client;
  AppViewMode get viewMode => _viewMode;
  void setViewMode(AppViewMode mode) {
    if (_viewMode == mode) return;
    _viewMode = mode;
    notifyListeners();
  }

  AppState({
    required this.servers,
    required this.terminalSettings,
    required this.commands,
    required this.push,
    required this.platform,
    this.embeddedServer,
    MotifClient Function(MotifServer server)? clientFactory,
    MotifClientRuntime? clientRuntime,
    ServerConnectionRuntime? serverConnectionRuntime,
  }) : startupActiveServerId = servers.activeId,
       _clientFactory =
           clientFactory ?? ((_) => MotifClient(runtime: clientRuntime)),
       _serverConnectionRuntime =
           serverConnectionRuntime ?? const MobileServerConnectionRuntime() {
    _transportResolver = TransportResolver(platform);
    servers.addListener(_relayStoreChange);
    commands.addListener(_relayStoreChange);
    push.addListener(_relayStoreChange);
    // One-way bridge: the client observes the embedded server's status and
    // registers/updates its loopback entry as a connectable target. The server
    // service stays unaware of the client's server list.
    embeddedServer?.addListener(_onEmbeddedServerChanged);
    terminalSettings.addListener(_onTerminalSettingsChanged);
    _tailscaleSub = platform.tailscale.states.listen(_onTailscaleState);
    try {
      _lifecycleListener = AppLifecycleListener(
        onPause: _onAppPaused,
        onHide: _onAppPaused,
        onResume: _onAppResumed,
      );
    } catch (_) {
      // No widgets binding (pure unit tests); lifecycle pausing is
      // best-effort.
    }
    _applyTerminalPalette();
  }

  static Future<AppState> load({
    PlatformServices? platform,
    Uri? embeddedWebUri,
    String embeddedWebToken = '',
    EmbeddedServerFactory? embeddedServerFactory,
    MotifClientRuntime? clientRuntime,
    ServerConnectionRuntime? serverConnectionRuntime,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final servers = ServerStore(prefs);
    if (servers.servers.isEmpty) {
      final launch = currentWebLaunchLocation();
      final server = embeddedWebServerFromUri(
        embeddedWebUri ?? launch?.uri ?? Uri(),
        token: embeddedWebUri == null
            ? (launch?.token ?? '')
            : embeddedWebToken,
      );
      if (server != null) {
        await servers.add(server);
        scrubWebLaunchToken();
      }
    }
    return AppState(
      servers: servers,
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: platform ?? PlatformServices.defaults(),
      embeddedServer: embeddedServerFactory == null
          ? null
          : await embeddedServerFactory(prefs),
      clientRuntime: clientRuntime,
      serverConnectionRuntime: serverConnectionRuntime,
    );
  }

  bool get hasActiveServer => servers.activeServer != null;

  bool shouldAutoConnectServer(String serverId) =>
      startupActiveServerId == serverId;

  MotifServer? serverById(String id) {
    for (final server in servers.servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  /// Create and persist a `rendezvous` server from a scanned/pasted
  /// `motif://pair` link. The single entry point that QR scanning, link
  /// pasting, and deep links all funnel through. Throws [FormatException] when
  /// the link is malformed; returns the new server id on success.
  Future<String> addServerFromPairingUri(String uri) async {
    final payload = MotifPairingPayload.parse(uri);
    final id = 'srv-${DateTime.now().microsecondsSinceEpoch}';
    await servers.add(payload.toServer(id: id));
    return id;
  }

  MotifClient? get activeClient {
    final id = servers.activeId;
    if (id == null) return null;
    return clientForServer(id);
  }

  MotifClient get motif {
    final client = activeClient;
    if (client == null) {
      throw StateError('No active server');
    }
    return client;
  }

  MotifClient? existingClientForServer(String serverId) =>
      _clientsByServer[serverId];

  MotifClient clientForServer(String serverId) {
    final existing = _clientsByServer[serverId];
    if (existing != null) return existing;
    final server = serverById(serverId);
    if (server == null) throw StateError('Unknown server: $serverId');
    final client = _clientFactory(server);
    _clientsByServer[serverId] = client;
    _controllersByServer[serverId] = ServerConnectionController(
      serverId: serverId,
      client: client,
      serverProvider: () => serverById(serverId),
      resolver: _transportResolver,
      onChanged: _relayControllerChange,
      runtime: _serverConnectionRuntime,
    );
    _wireClient(serverId, client);
    _applyTerminalPaletteTo(client);
    return client;
  }

  ServerConnectionController _controllerForServer(String serverId) {
    clientForServer(serverId);
    return _controllersByServer[serverId]!;
  }

  bool isServerLive(String serverId) =>
      existingClientForServer(serverId)?.isLive ?? false;

  MotifConnState serverState(String serverId) =>
      existingClientForServer(serverId)?.state ?? const ConnDisconnected();

  ServerConnectionState connectionStateForServer(String serverId) {
    final controller = _controllersByServer[serverId];
    if (controller != null) return controller.state;
    final server = serverById(serverId);
    if (server == null) return const ServerIdle();
    final blocker = _transportResolver.currentBlocker(server);
    return blocker == null ? const ServerIdle() : ServerBlocked(blocker);
  }

  TransportViewState transportViewStateForServer(String serverId) {
    final server = serverById(serverId);
    if (server == null) {
      return TransportViewState.direct(
        const MotifServer(id: '', name: '', host: ''),
      );
    }
    return _transportResolver.transportViewState(server);
  }

  ServerConnectionViewState serverViewState(String serverId) {
    final server = serverById(serverId);
    if (server == null) {
      return ServerConnectionViewState.from(
        server: const MotifServer(id: '', name: '', host: ''),
        state: const ServerIdle(),
        transport: TransportViewState.direct(
          const MotifServer(id: '', name: '', host: ''),
        ),
      );
    }
    return ServerConnectionViewState.from(
      server: server,
      state: connectionStateForServer(serverId),
      transport: _transportResolver.transportViewState(server),
    );
  }

  List<({MotifServer server, MotifClient client})> get connectedServerClients {
    final groups = <({MotifServer server, MotifClient client})>[];
    for (final server in servers.servers) {
      final client = _clientsByServer[server.id];
      if (client != null && client.isLive) {
        groups.add((server: server, client: client));
      }
    }
    return groups;
  }

  List<({MotifServer server, MotifClient client})> get knownServerClients {
    final groups = <({MotifServer server, MotifClient client})>[];
    for (final server in servers.servers) {
      final client = _clientsByServer[server.id];
      if (client != null) groups.add((server: server, client: client));
    }
    return groups;
  }

  void _relayStoreChange() {
    _pruneClientsForDeletedServers();
    notifyListeners();
  }

  /// The embedded server changed: keep its connectable loopback entry in sync,
  /// then propagate the change to listeners. This is the only place the client
  /// reaches into the server's state — the service never touches the client.
  void _onEmbeddedServerChanged() {
    unawaited(_syncEmbeddedServerEntry());
    _relayStoreChange();
  }

  /// Upsert the loopback [MotifServer] for the running embedded server so it
  /// appears in the connect flow. No-op until it has a loopback endpoint.
  Future<void> _syncEmbeddedServerEntry() async {
    final svc = embeddedServer;
    if (svc == null) return;
    final endpoint = svc.status.loopbackEndpoint;
    if (endpoint == null) return;

    // In LAN mode the embedded listener is TLS + psk-bearer even on loopback, so
    // the local client must speak https + pin + bearer. In Loopback mode it's
    // plaintext (and a bearer only when relay pairing is on). The pairing link
    // carries the psk (+ pin), which the resolver turns into the bearer.
    final isLan = svc.config.listenMode == EmbeddedListenMode.lan;
    final pairingUri = svc.status.pairingUri;
    var psk = '';
    var pubKey = '';
    if (pairingUri != null) {
      try {
        final p = MotifPairingPayload.parse(pairingUri);
        psk = base64Url.encode(p.psk).replaceAll('=', '');
        if (isLan && p.pubKey != null) {
          pubKey = base64Url.encode(p.pubKey!).replaceAll('=', '');
        }
      } catch (_) {
        // Unparseable link → fall back to a plaintext loopback entry.
      }
    }
    final desired = MotifServer(
      id: kEmbeddedServerId,
      name: 'This computer',
      host: endpoint.host,
      port: endpoint.port,
      scheme: isLan ? 'https' : 'http',
      kind: ServerKind.direct,
      psk: psk,
      pubKey: pubKey,
      directHosts: isLan ? [endpoint.host] : const [],
    );
    final existing = serverById(kEmbeddedServerId);
    if (existing == null) {
      await servers.add(desired);
    } else if (existing.host != desired.host ||
        existing.port != desired.port ||
        existing.scheme != desired.scheme ||
        existing.psk != desired.psk ||
        existing.pubKey != desired.pubKey) {
      await servers.update(desired);
    }
  }

  void _relayControllerChange() {
    if (hasListeners) notifyListeners();
  }

  void _onTerminalSettingsChanged() {
    _applyTerminalPalette();
    notifyListeners();
  }

  void _onTailscaleState(TailscaleState state) {
    for (final controller in _controllersByServer.values) {
      controller.handleTailscaleState(state);
    }
    notifyListeners();
  }

  void _onClientStateChanged(String serverId, MotifClient client) {
    _controllersByServer[serverId]?.handleClientStateChanged();
  }

  void _onAppPaused() {
    for (final controller in _controllersByServer.values) {
      controller.handleAppPaused();
    }
  }

  void _onAppResumed() {
    for (final controller in _controllersByServer.values) {
      controller.handleAppResumed();
    }
  }

  void _applyTerminalPalette() {
    final scheme = _resolveTerminalScheme(
      terminalSettings.settings.theme,
      ui.PlatformDispatcher.instance.platformBrightness,
    );
    final palette = terminalPaletteForBrightness(scheme);
    for (final client in _allClients()) {
      _applyTerminalPaletteTo(
        client,
        fg: palette.foregroundWire,
        bg: palette.backgroundWire,
        theme: palette.theme,
      );
    }
  }

  Iterable<MotifClient> _allClients() sync* {
    for (final client in _clientsByServer.values) {
      yield client;
    }
  }

  void _applyTerminalPaletteTo(
    MotifClient client, {
    String? fg,
    String? bg,
    String? theme,
  }) {
    if (fg == null && bg == null && theme == null) {
      final scheme = _resolveTerminalScheme(
        terminalSettings.settings.theme,
        ui.PlatformDispatcher.instance.platformBrightness,
      );
      final palette = terminalPaletteForBrightness(scheme);
      fg = palette.foregroundWire;
      bg = palette.backgroundWire;
      theme = palette.theme;
    }
    client.setTerminalPalette(fg: fg, bg: bg, theme: theme);
  }

  ui.Brightness _resolveTerminalScheme(
    TerminalThemeSetting setting,
    ui.Brightness platformBrightness,
  ) {
    return switch (setting) {
      TerminalThemeSetting.light => ui.Brightness.light,
      TerminalThemeSetting.dark => ui.Brightness.dark,
      TerminalThemeSetting.system =>
        platformBrightness == ui.Brightness.dark
            ? ui.Brightness.dark
            : ui.Brightness.light,
    };
  }

  /// Register this device for E2E push (native APNs token + the per-device AES
  /// key) once connected, if the user enabled notifications. Best-effort: a
  /// missing token / unsupported platform is a no-op. No Firebase involved.
  bool _pushHandlerWired = false;

  Future<void> registerForPush({MotifClient? client}) async {
    final target = client ?? activeClient;
    if (target == null || !push.enabled || !target.isLive) return;
    // Decrypt foreground push payloads in-app and surface them as banners
    // (background/killed delivery is decrypted by the iOS NSE).
    if (!_pushHandlerWired) {
      _pushHandlerWired = true;
      platform.push.onEncryptedPayload((e, n) async {
        final plain = await decryptPushPayload(
          encKeyB64: push.encKeyBase64,
          eB64: e,
          nB64: n,
        );
        if (plain == null) return;
        try {
          final obj = jsonDecode(plain) as Map<String, Object?>;
          if (push.isMuted(obj['session'] as String? ?? '')) return;
          target.showNotification(
            MotifNotification(
              title: (obj['title'] as String?) ?? 'Motif',
              body: (obj['body'] as String?) ?? '',
              sessionId: obj['session'] as String?,
              kind: (obj['kind'] as String?) ?? 'push',
            ),
          );
        } catch (_) {}
      });
    }
    try {
      final reg = await platform.push.register(encKeyBase64: push.encKeyBase64);
      if (reg == null) return;
      await target.registerDevice(
        deviceToken: reg.deviceToken,
        platform: reg.platform,
        encKeyBase64: reg.encKeyBase64,
        mutedSessions: push.mutedSessions.toList(),
      );
    } catch (_) {
      // Push is best-effort; never block the session on it.
    }
  }

  /// Connect (or reconnect) to the active server through the per-server
  /// connection controller.
  Future<void> connectActive({bool force = false}) async {
    final server = servers.activeServer;
    if (server == null) return;
    await connectServer(server.id, force: force, makeActive: false);
  }

  Future<void> connectServer(
    String serverId, {
    bool force = false,
    bool makeActive = true,
  }) async {
    final server = serverById(serverId);
    if (server == null) return;
    if (makeActive && servers.activeId != serverId) {
      await servers.setActive(serverId);
    }
    final client = clientForServer(server.id);
    await _controllerForServer(server.id).connect(force: force);
    // Best-effort push registration once the RPC channel is live.
    unawaited(registerForPush(client: client));
  }

  Future<bool> connectServerAndRefresh(
    String serverId, {
    bool force = false,
    bool makeActive = true,
  }) async {
    await connectServer(serverId, force: force, makeActive: makeActive);
    final client = existingClientForServer(serverId);
    if (client == null || !client.isLive) return false;
    await refreshServerSessions(serverId);
    return true;
  }

  Future<void> disconnectServer(String serverId) async {
    if (existingClientForServer(serverId) == null) return;
    await _controllerForServer(serverId).disconnect();
    notifyListeners();
  }

  Future<void> refreshConnectedSessions() async {
    await Future.wait([
      for (final group in connectedServerClients)
        _refreshClientSessions(group.server.id, group.client),
    ]);
    notifyListeners();
  }

  Future<void> refreshServerSessions(String serverId) async {
    final client = existingClientForServer(serverId);
    if (client == null || !client.isLive) return;
    await _refreshClientSessions(serverId, client);
    notifyListeners();
  }

  Future<void> _refreshClientSessions(
    String serverId,
    MotifClient client,
  ) async {
    try {
      await client.refreshSessions();
    } catch (e, st) {
      // Session refresh is best-effort; keep the list usable on transient RPC
      // failures, but hand stale transports to the reconnect controller.
      _controllersByServer[serverId]?.handleRefreshFailed(e, st);
    }
  }

  void _wireClient(String serverId, MotifClient client) {
    void listener() {
      _onClientStateChanged(serverId, client);
      if (hasListeners) notifyListeners();
    }

    _clientListeners[serverId] = listener;
    client.addListener(listener);
  }

  void _pruneClientsForDeletedServers() {
    final liveIds = {for (final server in servers.servers) server.id};
    for (final id in _clientsByServer.keys.toList()) {
      if (liveIds.contains(id)) continue;
      final client = _clientsByServer.remove(id);
      final listener = _clientListeners.remove(id);
      final controller = _controllersByServer.remove(id);
      controller?.dispose();
      if (client == null) continue;
      if (listener != null) client.removeListener(listener);
      unawaited(client.disconnect());
      client.dispose();
    }
  }

  @override
  void dispose() {
    servers.removeListener(_relayStoreChange);
    commands.removeListener(_relayStoreChange);
    push.removeListener(_relayStoreChange);
    embeddedServer?.removeListener(_onEmbeddedServerChanged);
    embeddedServer?.dispose();
    terminalSettings.removeListener(_onTerminalSettingsChanged);
    unawaited(_tailscaleSub?.cancel());
    _lifecycleListener?.dispose();
    for (final controller in _controllersByServer.values) {
      controller.dispose();
    }
    for (final entry in _clientsByServer.entries) {
      final listener = _clientListeners[entry.key];
      if (listener != null) entry.value.removeListener(listener);
    }
    for (final client in _clientsByServer.values) {
      client.dispose();
    }
    super.dispose();
  }
}

class SessionSidebarUiState {
  bool showSessions = false;
  bool showFileTree = false;
  bool showGitDiff = false;
  bool showBottomBar = false;
  double width = 340;
  double splitFraction = 0.5;
  double firstSplitFraction = 0.34;
  double secondSplitFraction = 0.67;

  bool get hasVisiblePanel => showSessions || showFileTree || showGitDiff;
}
