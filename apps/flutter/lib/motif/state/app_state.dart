/// Top-level app state, ported from `apps/ios/Motif/Settings/AppState.swift`.
///
/// Owns the persisted stores and live [MotifClient] workspaces. Mobile keeps a
/// single client per server; desktop can keep every server/session pair live.
/// Exposed to the widget tree via `provider`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:shared_preferences/shared_preferences.dart';

import '../log/log.dart';
import '../models/settings.dart';
import '../net/rzv/pairing_payload.dart';
import '../platform/web_launch.dart';
import '../platform/services.dart';
import '../terminal/terminal_palette.dart';
import 'connection_state.dart';
import 'embedded_server_service.dart';
import 'embedded_web_server.dart';
import 'motif_client.dart';
import 'motif_runtime.dart';
import 'push_coordinator.dart';
import 'server_connection_controller.dart';
import 'server_connection_runtime.dart';
import 'stores.dart';
import 'transport_resolver.dart';
import 'workspace_registry.dart';

/// Desktop top-level view selector: use the client (sessions/terminal) or
/// administer this machine's embedded server.
enum AppViewMode { client, server }

/// Request to open a session from an in-app notification / push tap.
class PendingSessionOpen {
  const PendingSessionOpen({required this.serverId, required this.session});

  final String serverId;
  final String session;
}

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
  final MotifClient Function(MotifServer server) _workspaceClientFactory;
  final ServerConnectionRuntime _serverConnectionRuntime;
  late final TransportResolver _transportResolver;
  late final PushCoordinator _pushCoordinator;
  final WorkspaceRegistry _workspaces = WorkspaceRegistry();
  final Map<MotifClient, VoidCallback> _clientListeners = {};
  final Map<String, Future<bool>> _serverConnectionTasks = {};
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

  /// Set when the user taps an in-app notification that names a session.
  /// Consumed by the client navigator (see `_PendingSessionOpenListener`).
  PendingSessionOpen? _pendingSessionOpen;
  PendingSessionOpen? get pendingSessionOpen => _pendingSessionOpen;

  /// Open [session] on [serverId] from a notification tap. Switches the
  /// desktop shell to the client pane when needed.
  void requestOpenSession({required String serverId, required String session}) {
    final trimmed = session.trim();
    if (serverId.isEmpty || trimmed.isEmpty) return;
    if (_viewMode != AppViewMode.client) {
      _viewMode = AppViewMode.client;
    }
    _pendingSessionOpen = PendingSessionOpen(
      serverId: serverId,
      session: trimmed,
    );
    notifyListeners();
  }

  /// Take and clear the pending open, or `null` if none.
  PendingSessionOpen? takePendingSessionOpen() {
    final pending = _pendingSessionOpen;
    if (pending == null) return null;
    _pendingSessionOpen = null;
    return pending;
  }

  /// Coordinates ⌘W between the session screen's global key handler and the
  /// app-level "hide window" shortcut. Both fire for one ⌘W press: Flutter runs
  /// the [HardwareKeyboard] handler (the session screen) before the focus-based
  /// `CallbackShortcuts` (the window-close binding), and the latter runs even
  /// when the former returns handled. The session screen sets this when it
  /// consumes ⌘W (closing a tab, or hiding on the last tab); the window-close
  /// binding reads-and-clears it to avoid hiding the window on top of that.
  /// Transient and intentionally does not notify listeners.
  bool _closeShortcutConsumed = false;
  void markCloseShortcutConsumed() => _closeShortcutConsumed = true;
  bool takeCloseShortcutConsumed() {
    final consumed = _closeShortcutConsumed;
    _closeShortcutConsumed = false;
    return consumed;
  }

  AppState({
    required this.servers,
    required this.terminalSettings,
    required this.commands,
    required this.push,
    required this.platform,
    this.embeddedServer,
    MotifClient Function(MotifServer server)? clientFactory,
    MotifClient Function(MotifServer server)? workspaceClientFactory,
    MotifClientRuntime? clientRuntime,
    ServerConnectionRuntime? serverConnectionRuntime,
  }) : startupActiveServerId = servers.activeId,
       _clientFactory =
           clientFactory ?? ((_) => MotifClient(runtime: clientRuntime)),
       _workspaceClientFactory =
           workspaceClientFactory ??
           clientFactory ??
           ((_) => MotifClient(runtime: clientRuntime)),
       _serverConnectionRuntime =
           serverConnectionRuntime ?? const MobileServerConnectionRuntime() {
    _transportResolver = TransportResolver(platform);
    _pushCoordinator = PushCoordinator(
      settings: push,
      service: platform.push,
      activeClient: () => activeClient,
      activeServerId: () => servers.activeId,
      primaryClients: () => _workspaces.primaryClientEntries,
      serverIdForClient: _serverIdForClient,
      serverExists: (id) => serverById(id) != null,
      requestOpenSession: requestOpenSession,
    );
    servers.addListener(_relayStoreChange);
    commands.addListener(_relayStoreChange);
    push.addListener(_onPushSettingsChanged);
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
    _pushCoordinator.start();
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
    final platformServices = platform ?? PlatformServices.defaults();
    final servers = await ServerStore.load(
      prefs,
      secrets: platformServices.secrets,
    );
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
      push: await PushSettingsStore.load(prefs, platformServices.secrets),
      platform: platformServices,
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

  /// Whether a server switched away from should stay attached (warm) instead of
  /// detaching. Driven by the platform [ServerConnectionRuntime] — desktop
  /// keeps background workspaces warm, mobile tears them down.
  bool get keepSessionWarmOnSwitchAway =>
      _serverConnectionRuntime.keepSessionWarmOnSwitchAway;

  int get maxRetainedWorkspaces =>
      _serverConnectionRuntime.maxRetainedWorkspaces;

  MotifClient get motif {
    final client = activeClient;
    if (client == null) {
      throw StateError('No active server');
    }
    return client;
  }

  MotifClient? existingClientForServer(String serverId) =>
      _workspaces.clientForServer(serverId);

  MotifClient clientForServer(String serverId) {
    final existing = _workspaces.clientForServer(serverId);
    if (existing != null) return existing;
    final server = serverById(serverId);
    if (server == null) throw StateError('Unknown server: $serverId');
    return _installActiveClient(
      server,
      _clientFactory(server),
      _transportResolver,
    );
  }

  /// Return the client that owns [session] on [serverId].
  ///
  /// Desktop keeps one live client per server/session workspace. Selecting a
  /// different workspace only parks the previous client in the warm pool; its
  /// HTTP, events and PTY streams remain attached. Mobile continues to use one
  /// client per server and lets the normal attach path replace its session.
  MotifClient clientForSession(String serverId, String session) {
    final active = clientForServer(serverId);
    if (!keepSessionWarmOnSwitchAway) return active;

    var currentSession = _workspaces.activeSessionForServer(serverId);
    currentSession ??= switch (active.state) {
      ConnAttached(:final session) => session,
      _ => active.intendedSession,
    };
    if (currentSession == null) {
      _workspaces.setActiveSession(serverId, session);
      active.prepareSessionReconnect(session);
      _setForegroundWorkspace(active);
      return active;
    }
    _workspaces.setActiveSession(serverId, currentSession);
    if (currentSession == session) {
      _setForegroundWorkspace(active);
      return active;
    }

    final currentKey = (serverId: serverId, session: currentSession);
    _workspaces.parkActive(currentKey);
    active.setForeground(false);

    final targetKey = (serverId: serverId, session: session);
    final targetSlot = _workspaces.activateWarm(targetKey);
    final target = targetSlot?.client;
    final targetController = targetSlot?.controller;
    final MotifClient next;
    final ServerConnectionController controller;
    if (target != null && targetController != null) {
      next = target;
      controller = targetController;
    } else {
      final server = serverById(serverId);
      if (server == null) throw StateError('Unknown server: $serverId');
      // Each warm workspace owns its own resolver/forwarder. This prevents a
      // reconnect on one rendezvous or SSH workspace from tearing down the
      // transport used by another live workspace on the same server.
      final resolver = TransportResolver(platform);
      next = _installActiveClient(
        server,
        _workspaceClientFactory(server),
        resolver,
      );
      controller = _workspaces.controllerForServer(serverId)!;
    }
    _workspaces.setActiveSession(serverId, session);
    next.prepareSessionReconnect(session);
    _setForegroundWorkspace(next);
    _pruneWarmWorkspaces();
    if (!next.isLive) {
      unawaited(
        Future<void>.microtask(controller.connect).catchError((
          Object e,
          StackTrace st,
        ) {
          Log.w(
            'warm workspace connect failed server=$serverId session=$session',
            name: 'motif.session',
            error: e,
            stackTrace: st,
          );
        }),
      );
    }
    return next;
  }

  /// Keep the desktop workspace cache bounded. The active workspace lives in
  /// the registry's active slot, so the warm pool retains at most `limit - 1`.
  void _pruneWarmWorkspaces() {
    final warmLimit = (maxRetainedWorkspaces - 1).clamp(0, 1 << 20);
    for (final evicted in _workspaces.evictWarmBeyond(warmLimit)) {
      final key = evicted.$1;
      final client = evicted.$2.client;
      evicted.$2.controller.dispose();

      final listener = _clientListeners.remove(client);
      if (listener != null) client.removeListener(listener);
      _pushCoordinator.removeClient(client);
      Log.i(
        'evict warm workspace server=${key.serverId} session=${key.session}',
        name: 'motif.session',
      );
      unawaited(client.disconnect().whenComplete(client.dispose));
    }
  }

  MotifClient _installActiveClient(
    MotifServer server,
    MotifClient client,
    TransportResolver resolver,
  ) {
    final controller = ServerConnectionController(
      serverId: server.id,
      client: client,
      serverProvider: () => serverById(server.id),
      resolver: resolver,
      onChanged: _relayControllerChange,
      runtime: _serverConnectionRuntime,
    );
    _workspaces.installActive(
      server.id,
      WorkspaceSlot(client: client, controller: controller),
    );
    _wireClient(server.id, client, controller);
    _applyTerminalPaletteTo(client);
    return client;
  }

  ServerConnectionController _controllerForServer(String serverId) {
    clientForServer(serverId);
    return _workspaces.controllerForServer(serverId)!;
  }

  bool isServerLive(String serverId) =>
      existingClientForServer(serverId)?.isLive ?? false;

  MotifConnState serverState(String serverId) =>
      existingClientForServer(serverId)?.state ?? const ConnDisconnected();

  ServerConnectionState connectionStateForServer(String serverId) {
    final controller = _workspaces.controllerForServer(serverId);
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
      final client = _workspaces.clientForServer(server.id);
      if (client != null && client.isLive) {
        groups.add((server: server, client: client));
      }
    }
    return groups;
  }

  List<({MotifServer server, MotifClient client})> get knownServerClients {
    final groups = <({MotifServer server, MotifClient client})>[];
    for (final server in servers.servers) {
      final client = _workspaces.clientForServer(server.id);
      if (client != null) groups.add((server: server, client: client));
    }
    return groups;
  }

  /// Every connected workspace, including desktop sessions parked in the
  /// background. Used by explicit close/disconnect actions; ordinary switches
  /// deliberately leave these clients alone.
  Iterable<MotifClient> get connectedWorkspaceClients =>
      _allClients().where((client) => client.isLive);

  void _relayStoreChange() {
    _pruneClientsForDeletedServers();
    notifyListeners();
  }

  void _onPushSettingsChanged() {
    _pushCoordinator.onSettingsChanged();
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
    for (final controller in _allControllers()) {
      controller.handleTailscaleState(state);
    }
    notifyListeners();
  }

  void _onClientStateChanged(
    String serverId,
    MotifClient client,
    ServerConnectionController controller,
  ) {
    // The client notifier carries both connection transitions and ordinary
    // session/view data updates. Project connection state without notifying
    // here; [_wireClient] emits one app notification after all related maps and
    // push bookkeeping have converged.
    controller.handleClientStateChanged(notify: false);
    final state = client.state;
    if (identical(_workspaces.clientForServer(serverId), client)) {
      if (state is ConnAttached) {
        _workspaces.setActiveSession(serverId, state.session);
      } else if (state is ConnConnected && client.intendedSession == null) {
        _workspaces.setActiveSession(serverId, null);
      }
    }
    _pushCoordinator.onClientChanged(
      serverId,
      client,
      anyClientLiveForServer: _clientsForServer(
        serverId,
      ).any((candidate) => candidate.isLive),
    );
  }

  void _onAppPaused() {
    for (final controller in _allControllers()) {
      controller.handleAppPaused();
    }
  }

  void _onAppResumed() {
    if (keepSessionWarmOnSwitchAway) {
      // Only the visible desktop workspace may reclaim terminal primary/theme.
      // Background workspaces stay connected but remain non-foreground.
      final activeId = servers.activeId;
      final activeController = activeId == null
          ? null
          : _workspaces.controllerForServer(activeId);
      activeController?.handleAppResumed();
    } else {
      for (final controller in _allControllers()) {
        controller.handleAppResumed();
      }
    }
    _pushCoordinator.onAppResumed();
  }

  @visibleForTesting
  void debugHandleAppResumed() => _onAppResumed();

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

  Iterable<MotifClient> _allClients() => _workspaces.clients;

  Iterable<MotifClient> _clientsForServer(String serverId) =>
      _workspaces.clientsForServer(serverId);

  Iterable<ServerConnectionController> _allControllers() =>
      _workspaces.controllers;

  void _setForegroundWorkspace(MotifClient foreground) {
    for (final client in _allClients()) {
      client.setForeground(identical(client, foreground));
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

  Future<void> registerForPush({MotifClient? client}) =>
      _pushCoordinator.registerForPush(client: client);

  String? _serverIdForClient(MotifClient client) =>
      _workspaces.serverIdForClient(client);

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
    await _controllerForServer(server.id).connect(force: force);
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

  /// Join an existing connection attempt for [serverId], or start one. This is
  /// used by startup and notification deep links so they cannot race two
  /// transports for the same client.
  Future<bool> ensureServerConnectedAndRefresh(
    String serverId, {
    bool force = false,
    bool makeActive = true,
  }) {
    if (!force && isServerLive(serverId)) {
      return (() async {
        await refreshServerSessions(serverId);
        return isServerLive(serverId);
      })();
    }
    if (!force) {
      final existing = _serverConnectionTasks[serverId];
      if (existing != null) return existing;
    }

    final raw = connectServerAndRefresh(
      serverId,
      force: force,
      makeActive: makeActive,
    );
    late final Future<bool> task;
    task = (() async {
      try {
        return await raw;
      } finally {
        if (identical(_serverConnectionTasks[serverId], task)) {
          _serverConnectionTasks.remove(serverId);
        }
      }
    })();
    _serverConnectionTasks[serverId] = task;
    return task;
  }

  Future<void> disconnectServer(String serverId) async {
    if (existingClientForServer(serverId) == null) return;
    final controllers = _workspaces.controllersForServer(serverId).toList();
    await Future.wait([
      for (final controller in controllers) controller.disconnect(),
    ]);
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
      _workspaces.controllerForServer(serverId)?.handleRefreshFailed(e, st);
    }
  }

  void _wireClient(
    String serverId,
    MotifClient client,
    ServerConnectionController controller,
  ) {
    void listener() {
      _onClientStateChanged(serverId, client, controller);
      if (hasListeners) notifyListeners();
    }

    _clientListeners[client] = listener;
    client.addListener(listener);
  }

  void _pruneClientsForDeletedServers() {
    final liveIds = {for (final server in servers.servers) server.id};
    unawaited(push.retainInstanceServers(liveIds));
    for (final removed in _workspaces.removeDeletedServers(liveIds)) {
      final id = removed.$1;
      final client = removed.$2.client;
      removed.$2.controller.dispose();
      final listener = _clientListeners.remove(client);
      _pushCoordinator.removeClient(client);
      _pushCoordinator.removeServer(id);
      _serverConnectionTasks.remove(id);
      if (listener != null) client.removeListener(listener);
      unawaited(client.disconnect());
      client.dispose();
    }
  }

  @override
  void dispose() {
    servers.removeListener(_relayStoreChange);
    commands.removeListener(_relayStoreChange);
    push.removeListener(_onPushSettingsChanged);
    _pushCoordinator.dispose();
    embeddedServer?.removeListener(_onEmbeddedServerChanged);
    embeddedServer?.dispose();
    terminalSettings.removeListener(_onTerminalSettingsChanged);
    unawaited(_tailscaleSub?.cancel());
    _lifecycleListener?.dispose();
    for (final controller in _allControllers()) {
      controller.dispose();
    }
    for (final client in _allClients()) {
      final listener = _clientListeners[client];
      if (listener != null) client.removeListener(listener);
    }
    for (final client in _allClients()) {
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
