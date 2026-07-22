/// Top-level app state, ported from `apps/ios/Motif/Settings/AppState.swift`.
///
/// Owns persisted stores plus the process-wide Server/Workspace runtime trees.
/// Exposed to the widget tree through an Observation scope.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:shared_preferences/shared_preferences.dart';

import '../../log/log.dart';
import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../net/rzv/pairing_payload.dart';
import '../../platform/web_launch.dart';
import '../../platform/services.dart';
import '../../terminal/terminal_palette.dart';
import 'app_runtime_controller.dart';
import 'app_runtime_state.dart';
import 'app_ui_state.dart';
import 'app_view_model.dart';
import '../connection/connection_state.dart';
import '../server/device_controller.dart';
import '../server/device_registration_view_model.dart';
import '../embedded/embedded_server_service.dart';
import '../embedded/embedded_web_server.dart';
import '../workspace/connection/workspace_connection_controller.dart';
import '../workspace/connection/workspace_connection_view_model.dart';
import '../workspace/workspace_content_view_model.dart';
import '../workspace/terminal/terminal_controller.dart';
import '../workspace/view/view_controller.dart';
import '../workspace/remote_port/remote_port_controller.dart';
import '../workspace/terminal/terminal_runtime_policy.dart';
import '../server/push_coordinator.dart';
import '../server/server_access_controller.dart';
import '../workspace/workspace_lifecycle_controller.dart';
import '../workspace/workspace_retention_policy.dart';
import '../server/server_instance.dart';
import '../server/server_runtime_state.dart';
import '../server/server_transport.dart';
import '../server/server_view_models.dart';
import '../server/session_catalog_controller.dart';
import '../server/session_catalog_view_model.dart';
import '../workspace/session_attachment.dart';
import '../persistence/stores.dart';
import '../server/transport_resolver.dart';
import '../workspace/workspace_view_model.dart';
import '../workspace/workspace_instance.dart';
import '../workspace/workspace_api.dart';
import '../workspace/workspace_registry.dart';

export 'app_ui_state.dart'
    show AppLifecyclePhase, AppViewMode, PendingSessionOpen;

class AppState {
  final ServerStore servers;
  final TerminalSettingsStore terminalSettings;
  final QuickCommandStore commands;
  final PushSettingsStore push;
  final PlatformServices platform;

  /// Desktop-only embedded motifd (run from the tray). Null on web/mobile or
  /// when the native library isn't bundled.
  final EmbeddedServerService? embeddedServer;
  final String? startupActiveServerId;
  final SessionSidebarViewModel sessionSidebar = SessionSidebarViewModel();
  late final AppShellViewModel shell;
  late final ServerRegistryViewModel serverRegistryViewModel;
  late final AppViewModel viewModel;
  final ServerTransport Function(MotifServer server) _serverTransportFactory;
  final WorkspaceConnectionController Function(
    MotifServer server,
    String session,
  )
  _workspaceConnectionFactory;
  final WorkspaceRetentionPolicy _workspaceRetentionPolicy;
  late final TransportResolver _transportResolver;
  late final PushCoordinator _pushCoordinator;
  late final AppRuntimeController _runtime;
  final Map<String, ServerInstance> _serverInstances = {};
  final WorkspaceRegistry _workspaces = WorkspaceRegistry();
  bool _disposed = false;
  late final ObservationSubscription<
    ({List<MotifServer> servers, String? activeId})
  >
  _serversSubscription;
  late final ObservationSubscription<
    ({bool enabled, Set<String> mutedSessions})
  >
  _pushSubscription;
  late final ObservationSubscription<TerminalSettings>
  _terminalSettingsSubscription;
  ObservationSubscription<
    ({bool available, EmbeddedServerConfig config, EmbeddedServerStatus status})
  >?
  _embeddedServerSubscription;
  late final ObservationSubscription<TailscaleState> _tailscaleSubscription;
  AppLifecycleListener? _lifecycleListener;

  /// Desktop top-level view: the client (sessions) or the embedded-server
  /// control panel. Only meaningful when [embeddedServer] is available; the UI
  /// shell shows the switch in that case.
  AppViewMode get viewMode => shell.viewMode;
  void setViewMode(AppViewMode mode) {
    if (shell.viewMode == mode) return;
    shell.viewMode = mode;
  }

  /// Set when the user taps an in-app notification that names a session.
  /// Consumed by the client navigator (see `_PendingSessionOpenListener`).
  PendingSessionOpen? get pendingSessionOpen => shell.pendingSessionOpen;

  /// Open [session] on [serverId] from a notification tap. Switches the
  /// desktop shell to the client pane when needed.
  void requestOpenSession({
    required String serverId,
    required String session,
    String? viewId,
  }) {
    final trimmed = session.trim();
    if (serverId.isEmpty || trimmed.isEmpty) return;
    observationTransaction(() {
      shell.viewMode = AppViewMode.client;
      shell.pendingSessionOpen = PendingSessionOpen(
        serverId: serverId,
        session: trimmed,
        viewId: viewId?.trim().isNotEmpty == true ? viewId!.trim() : null,
      );
    });
  }

  /// Take and clear the pending open, or `null` if none.
  PendingSessionOpen? takePendingSessionOpen() {
    final pending = shell.pendingSessionOpen;
    if (pending == null) return null;
    shell.pendingSessionOpen = null;
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
    ServerTransport Function(MotifServer server)? serverTransportFactory,
    WorkspaceConnectionController Function(MotifServer server, String session)?
    workspaceConnectionFactory,
    TerminalRuntimePolicy? terminalRuntime,
    WorkspaceRetentionPolicy? workspaceRetentionPolicy,
  }) : startupActiveServerId = servers.activeId,
       _serverTransportFactory =
           serverTransportFactory ?? ((_) => RpcServerTransport()),
       _workspaceConnectionFactory =
           workspaceConnectionFactory ??
           ((_, session) => WorkspaceConnectionController(
             session: session,
             runtime: terminalRuntime,
           )),
       _workspaceRetentionPolicy =
           workspaceRetentionPolicy ?? const MobileWorkspaceRetentionPolicy() {
    shell = AppShellViewModel(sidebar: sessionSidebar);
    _transportResolver = TransportResolver(platform);
    serverRegistryViewModel = ServerRegistryViewModel(
      activeServerId: servers.activeId,
      order: ObservableList(),
      entries: ObservableMap(),
    );
    _syncServerViewModels();
    viewModel = AppViewModel(
      shell: shell,
      preferences: PreferencesViewModel(
        terminal: terminalSettings.viewModel,
        quickCommands: commands.viewModel,
        push: push.viewModel,
      ),
      platform: PlatformViewModel(
        tailscale: platform.tailscale.viewModel,
        embeddedServer: embeddedServer?.viewModel,
      ),
      servers: serverRegistryViewModel,
    );
    _pushCoordinator = PushCoordinator(
      settings: push,
      service: platform.push,
      activeServerId: () => servers.activeId,
      serverEndpoints: _pushServerEndpoints,
      serverExists: (id) => serverById(id) != null,
      showNotification: _showServerNotification,
      requestOpenSession: requestOpenSession,
    );
    _runtime = AppRuntimeController(
      connectStartupServer: _connectStartupServerEffect,
      applyLifecycle: _applyRuntimeLifecycle,
      onStateChanged: (state) {
        observationTransaction(() {
          shell.runtime = state;
          shell.lifecycle = state.lifecycle is AppRuntimeForeground
              ? AppLifecyclePhase.foreground
              : AppLifecyclePhase.background;
        });
      },
    );
    _serversSubscription = observe(
      () => (servers: servers.servers.toList(), activeId: servers.activeId),
      onChange: (_) => _relayStoreChange(),
      scheduler: ObservationSchedulers.immediate,
    );
    _pushSubscription = observe(
      () => (enabled: push.enabled, mutedSessions: push.mutedSessions.toSet()),
      onChange: (_) => _onPushSettingsChanged(),
      scheduler: ObservationSchedulers.immediate,
    );
    // One-way bridge: the app observes the embedded server's status and
    // registers/updates its loopback entry as a connectable target. The server
    // service stays unaware of the app's server list.
    final embedded = embeddedServer;
    if (embedded != null) {
      _embeddedServerSubscription = observe(
        () => (
          available: embedded.available,
          config: embedded.config,
          status: embedded.status,
        ),
        onChange: (_) => _onEmbeddedServerChanged(),
        scheduler: ObservationSchedulers.immediate,
      );
    }
    _terminalSettingsSubscription = observe(
      () => terminalSettings.settings,
      onChange: (_) => _onTerminalSettingsChanged(),
      scheduler: ObservationSchedulers.immediate,
    );
    _tailscaleSubscription = observe(
      () => platform.tailscale.state,
      onChange: _onTailscaleState,
      scheduler: ObservationSchedulers.immediate,
    );
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
    TerminalRuntimePolicy? terminalRuntime,
    WorkspaceRetentionPolicy? workspaceRetentionPolicy,
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
          : await embeddedServerFactory(prefs, platformServices.secrets),
      terminalRuntime: terminalRuntime,
      workspaceRetentionPolicy: workspaceRetentionPolicy,
    );
  }

  bool get hasActiveServer => servers.activeServer != null;

  bool shouldAutoConnectServer(String serverId) =>
      startupActiveServerId == serverId;

  AppRuntimeState get runtimeState => _runtime.state;

  /// Auto-connects the server that was active when this process started.
  ///
  /// A managed embedded server can take several seconds to bind its loopback
  /// endpoint while Tailscale or rendezvous starts. Probing the persisted
  /// profile before then leaves the client blocked even though motifd becomes
  /// reachable moments later, so defer that startup connection until
  /// [_syncEmbeddedServerEntry] observes the bound endpoint.
  Future<void> autoConnectStartupServer() async {
    final server = servers.activeServer;
    if (server == null || !shouldAutoConnectServer(server.id)) {
      await _runtime.start(serverId: null, waitForEmbedded: false);
      return;
    }

    final embedded = embeddedServer;
    final waitForEmbedded =
        server.id == kEmbeddedServerId &&
        embedded != null &&
        embedded.available &&
        embedded.config.autostart &&
        embedded.status.loopbackEndpoint == null &&
        embedded.status.error == null;
    if (waitForEmbedded) {
      Log.i(
        'defer local startup connect until embedded endpoint is ready',
        name: 'motif.embedded',
      );
    }
    await _runtime.start(serverId: server.id, waitForEmbedded: waitForEmbedded);
  }

  Future<bool> _connectStartupServerEffect(String serverId) async {
    if (_disposed ||
        startupActiveServerId != serverId ||
        servers.activeId != serverId) {
      return false;
    }
    try {
      return await ensureServerConnectedAndRefresh(serverId, makeActive: false);
    } catch (error, stackTrace) {
      Log.w(
        'startup server connect failed server=$serverId',
        name: 'motif.connect',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

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

  /// Whether a server switched away from should stay attached (warm) instead of
  /// detaching. Driven by [WorkspaceRetentionPolicy] — desktop
  /// keeps background workspaces warm, mobile tears them down.
  bool get keepSessionWarmOnSwitchAway =>
      _workspaceRetentionPolicy.keepSessionWarmOnSwitchAway;

  int get maxRetainedWorkspaces =>
      _workspaceRetentionPolicy.maxRetainedWorkspaces;
  ServerInstance? existingServerInstance(String serverId) =>
      _serverInstances[serverId];

  ServerInstance serverInstance(String serverId) {
    final existing = _serverInstances[serverId];
    if (existing != null) return existing;
    final profile = serverById(serverId);
    if (profile == null) throw StateError('Unknown server: $serverId');
    _syncServerViewModels();
    final viewModel = serverRegistryViewModel.entries[serverId]!;
    final transport = _serverTransportFactory(profile);
    final sessions = SessionCatalogController(
      viewModel: viewModel.sessions,
      transport: SessionCatalogTransport(
        isAvailable: () => transport.isLive,
        call: transport.call,
      ),
    );
    final device = DeviceController(
      viewModel: viewModel.device,
      transport: DeviceTransport(
        isAvailable: () => transport.isLive,
        call: transport.call,
      ),
    );
    final workspace = WorkspaceApi(
      content: WorkspaceContentViewModel(),
      transport: WorkspaceApiTransport(
        isAvailable: () => transport.isLive,
        call: transport.call,
        writeFileBytes: transport.writeFileBytes,
      ),
      activeCwd: () => null,
    );
    late final ServerInstance instance;
    final access = ServerAccessController(
      serverId: serverId,
      serverProvider: () => serverById(serverId),
      resolver: _transportResolver,
      transport: transport,
      sessions: sessions,
      viewModel: viewModel.access,
      onChanged: () => _onServerAccessChanged(instance),
    );
    instance = ServerInstance(
      viewModel: viewModel,
      transport: transport,
      access: access,
      sessions: sessions,
      device: device,
      workspace: workspace,
    );
    _serverInstances[serverId] = instance;
    _onServerAccessChanged(instance);
    return instance;
  }

  WorkspaceInstance? existingWorkspace(String serverId, String session) =>
      _workspaces.instanceFor((serverId: serverId, session: session));

  WorkspaceInstance workspaceForSession(String serverId, String session) {
    final profile = serverById(serverId);
    if (profile == null) throw StateError('Unknown server: $serverId');
    serverInstance(serverId);
    final key = (serverId: serverId, session: session);
    final current = _workspaces.activeForServer(serverId);
    if (current?.key == key) {
      _setForegroundWorkspace(current!);
      return current;
    }

    if (current != null) {
      _workspaces.parkActive(current.key);
      final registry = serverRegistryViewModel.entries[serverId]!.workspaces;
      if (!registry.warmOrder.contains(current.key.session)) {
        registry.warmOrder.add(current.key.session);
      }
      current.lifecycle.setForeground(false);
    }

    var target = _workspaces.activateWarm(key);
    target ??= _createWorkspace(profile, key);
    _workspaces.installActive(target);
    final registry = serverRegistryViewModel.entries[serverId]!.workspaces;
    observationTransaction(() {
      registry.activeSession = session;
      registry.warmOrder.remove(session);
      registry.retained[session] = target!.viewModel;
    });
    _setForegroundWorkspace(target);
    _pruneWarmWorkspaces();
    if (!target.isLive) {
      unawaited(
        Future<void>.microtask(target.lifecycle.connect).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          Log.w(
            'workspace connect failed server=$serverId session=$session',
            name: 'motif.session',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
    }
    return target;
  }

  WorkspaceInstance _createWorkspace(MotifServer profile, WorkspaceKey key) {
    final connection = _workspaceConnectionFactory(profile, key.session);
    final resolver = TransportResolver(platform);
    final lifecycle = WorkspaceLifecycleController(
      serverId: profile.id,
      connection: connection,
      serverProvider: () => serverById(profile.id),
      resolver: resolver,
      retentionPolicy: _workspaceRetentionPolicy,
    );
    final instance = WorkspaceInstance.compose(
      key: key,
      connection: connection,
      lifecycle: lifecycle,
    );
    _applyTerminalPaletteTo(connection);
    return instance;
  }

  void _pruneWarmWorkspaces() {
    final warmLimit = (maxRetainedWorkspaces - 1).clamp(0, 1 << 20);
    for (final instance in _workspaces.evictWarmBeyond(warmLimit)) {
      final key = instance.key;
      final registry =
          serverRegistryViewModel.entries[key.serverId]?.workspaces;
      registry?.retained.remove(key.session);
      registry?.warmOrder.remove(key.session);
      Log.i(
        'evict warm workspace server=${key.serverId} session=${key.session}',
        name: 'motif.session',
      );
      unawaited(instance.closeAndDispose());
    }
  }

  bool isServerLive(String serverId) =>
      existingServerInstance(serverId)?.isLive ?? false;

  WorkspaceConnectionStatus serverState(String serverId) {
    final instance = existingServerInstance(serverId);
    if (instance == null) return const ConnDisconnected();
    return switch (instance.viewModel.access.runtime.visibleState) {
      ServerRuntimeDisconnected() ||
      ServerRuntimeDisconnecting() => const ConnDisconnected(),
      ServerRuntimeSynchronizing() => const ConnConnecting(),
      ServerRuntimeRecovering(:final error) => ConnFailed('$error'),
      ServerRuntimeOnline() => const ConnConnected(),
      ServerRuntimeBlocked(:final blocker) => ConnSuspended(blocker.message),
      ServerRuntimePaused() => throw StateError(
        'visibleState must unwrap paused state',
      ),
    };
  }

  ServerConnectionState connectionStateForServer(String serverId) {
    final controller = existingServerInstance(serverId)?.access;
    if (controller != null) {
      // Establish an Observation dependency on the authoritative runtime
      // state, while keeping command behavior on the controller facade.
      existingServerInstance(serverId)!.viewModel.access.runtime;
      return controller.state;
    }
    final access = serverRegistryViewModel.entries[serverId]?.access;
    if (access != null) {
      return switch (access.phase) {
        ServerAccessPhase.idle => const ServerIdle(),
        ServerAccessPhase.resolving => const ServerConnecting(),
        ServerAccessPhase.ready => const ServerConnected(),
        ServerAccessPhase.blocked => ServerBlocked(
          access.blocker ??
              ConnectionBlocker.transport(
                'transport unavailable',
                kind: serverById(serverId)?.kind ?? ServerKind.direct,
              ),
        ),
        ServerAccessPhase.failed => ServerFailed(
          access.error ?? 'connection failed',
        ),
      };
    }
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

  /// Observable server projections that currently have a live primary
  /// transport. UI reads session catalogs from these view models and never
  /// needs access to the transport-owning runtime object.
  List<ServerViewModel> get connectedServers {
    final result = <ServerViewModel>[];
    for (final serverId in serverRegistryViewModel.order) {
      final viewModel = serverRegistryViewModel.entries[serverId];
      // Read the observable access phase before consulting the runtime map.
      // The runtime may not exist during the first UI build, and adding it to
      // _serverInstances is intentionally not itself UI state.
      if (viewModel == null || !viewModel.access.isReady) continue;
      if (_serverInstances[serverId] != null) result.add(viewModel);
    }
    return result;
  }

  List<
    ({
      ServerViewModel viewModel,
      SessionCatalogController sessions,
      WorkspaceApi workspace,
      bool isLive,
    })
  >
  get connectedServerCapabilities {
    final result =
        <
          ({
            ServerViewModel viewModel,
            SessionCatalogController sessions,
            WorkspaceApi workspace,
            bool isLive,
          })
        >[];
    for (final serverId in serverRegistryViewModel.order) {
      final viewModel = serverRegistryViewModel.entries[serverId];
      // Keep this projection observable even when startup creates the runtime
      // after the first frame. ServerAccessViewModel is the UI source of truth;
      // ServerTransport.isLive remains an internal runtime detail.
      if (viewModel == null || !viewModel.access.isReady) continue;
      final instance = _serverInstances[serverId];
      if (instance == null) continue;
      result.add((
        viewModel: viewModel,
        sessions: instance.sessions,
        workspace: instance.workspace,
        isLive: viewModel.access.isReady,
      ));
    }
    return result;
  }

  Future<void> destroySession(String serverId, String session) async {
    final instance = serverInstance(serverId);
    final removed = instance.sessions.removeOptimistically(session);
    try {
      await instance.sessions.destroyRemote(session);
    } catch (_) {
      instance.sessions.restore(removed);
      rethrow;
    }
    try {
      await instance.access.refreshSessions();
    } catch (error, stackTrace) {
      Log.w(
        'session list refresh after destroy failed session=$session',
        name: 'motif.session',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Iterable<WorkspaceInstance> get connectedWorkspaces =>
      _workspaces.instances.where((instance) => instance.isLive);

  /// Detach every attached workspace while keeping server-side sessions alive.
  /// This is an app-level operation because one UI action may span multiple
  /// servers and retained desktop workspaces.
  Future<void> detachAllSessions() async {
    final attachments = [
      for (final instance in _workspaces.instances)
        if (instance.viewModel.connection.isAttached) instance.attachment,
    ];
    await Future.wait([
      for (final attachment in attachments) attachment.detach(),
    ]);
  }

  /// Prepare runtime ownership for a workspace selection. Navigation remains
  /// a presentation concern; foregrounding, warm retention and attachment
  /// replacement are coordinated here at the composition boundary.
  void prepareWorkspaceSelection({
    required String fromServerId,
    required String fromSession,
    required String toServerId,
    required String toSession,
  }) {
    if (fromServerId == toServerId && fromSession == toSession) return;

    final current = _workspaces.activeForServer(fromServerId);
    if (keepSessionWarmOnSwitchAway) {
      current?.lifecycle.setForeground(false);
    } else if (current != null &&
        current.key != (serverId: toServerId, session: toSession)) {
      unawaited(
        current.attachment.detach().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          Log.w(
            'background detach failed while switching sessions',
            name: 'motif.ui',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
    }
    workspaceForSession(toServerId, toSession);

    unawaited(
      servers.setActive(toServerId).catchError((Object error, StackTrace st) {
        Log.w(
          'persist active server failed during session switch',
          name: 'motif.ui',
          error: error,
          stackTrace: st,
        );
      }),
    );
  }

  void _relayStoreChange() {
    _syncServerViewModels();
    _pruneInstancesForDeletedServers();
  }

  void _syncServerViewModels() {
    final profiles = servers.servers;
    final liveIds = {for (final profile in profiles) profile.id};
    observationTransaction(() {
      serverRegistryViewModel
        ..activeServerId = servers.activeId
        ..order.replaceRange(
          0,
          serverRegistryViewModel.order.length,
          profiles.map((profile) => profile.id),
        );
      serverRegistryViewModel.entries.removeWhere(
        (id, _) => !liveIds.contains(id),
      );
      for (final profile in profiles) {
        final existing = serverRegistryViewModel.entries[profile.id];
        if (existing != null) {
          existing.profile = profile;
          continue;
        }
        serverRegistryViewModel.entries[profile.id] = ServerViewModel(
          profile: profile,
          access: ServerAccessViewModel(
            transport: _transportResolver.transportViewState(profile),
          ),
          sessions: SessionCatalogViewModel(sessions: ObservableList()),
          device: DeviceRegistrationViewModel(),
          workspaces: WorkspaceRegistryViewModel(
            warmOrder: ObservableList(),
            retained: ObservableMap(),
          ),
        );
      }
    });
  }

  ({
    WorkspaceViewModel viewModel,
    SessionAttachment attachment,
    TerminalController terminal,
    ViewController views,
    WorkspaceApi workspace,
    RemotePortController remotePorts,
  })
  workspaceCapabilities(String serverId, String session) {
    final instance = workspaceForSession(serverId, session);
    return (
      viewModel: instance.viewModel,
      attachment: instance.attachment,
      terminal: instance.terminal,
      views: instance.views,
      workspace: instance.workspace,
      remotePorts: instance.remotePorts,
    );
  }

  void _onPushSettingsChanged() {
    _pushCoordinator.onSettingsChanged();
  }

  /// The embedded server changed: keep its connectable loopback entry in sync,
  /// then propagate the change to observers. This is the only place the app
  /// reaches into the server's state — the service never touches the app.
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
    Log.i(
      'embedded endpoint ready endpoint=${desired.endpoint}',
      name: 'motif.embedded',
    );
    _runtime.embeddedReady(kEmbeddedServerId);
  }

  void _onTerminalSettingsChanged() {
    _applyTerminalPalette();
  }

  void _onTailscaleState(TailscaleState state) {
    for (final instance in _serverInstances.values) {
      instance.access.handleTailscaleState(state);
    }
    for (final controller in _workspaceLifecycles()) {
      controller.handleTailscaleState(state);
    }
  }

  void _onServerAccessChanged(ServerInstance instance) {
    _pushCoordinator.onServerChanged((
      serverId: instance.id,
      isLive: instance.isLive,
      device: instance.device,
    ));
  }

  Iterable<PushServerEndpoint> _pushServerEndpoints() sync* {
    for (final instance in _serverInstances.values) {
      yield (
        serverId: instance.id,
        isLive: instance.isLive,
        device: instance.device,
      );
    }
  }

  void _showServerNotification(
    String serverId,
    MotifNotification notification,
  ) {
    final session = notification.sessionId;
    final target = session == null
        ? _workspaces.activeForServer(serverId)
        : _workspaces.instanceFor((serverId: serverId, session: session));
    if (target != null) {
      target.viewModel.presence.latestNotification = notification;
    }
  }

  ({WorkspaceKey key, MotifNotification notification})?
  get currentNotification {
    for (final serverId in serverRegistryViewModel.order) {
      final registry = serverRegistryViewModel.entries[serverId]?.workspaces;
      if (registry == null) continue;
      for (final workspace in registry.retained.values) {
        final notification = workspace.presence.latestNotification;
        if (notification != null) {
          return (key: workspace.key, notification: notification);
        }
      }
    }
    return null;
  }

  void consumeNotification(WorkspaceKey key) {
    final workspace = serverRegistryViewModel
        .entries[key.serverId]
        ?.workspaces
        .retained[key.session];
    if (workspace != null) workspace.presence.latestNotification = null;
  }

  void _onAppPaused() {
    _runtime.setForeground(false);
  }

  void _onAppResumed() {
    _runtime.setForeground(true);
  }

  void _applyRuntimeLifecycle(bool foreground) {
    if (!foreground) {
      for (final instance in _serverInstances.values) {
        instance.access.handleAppPaused();
      }
      for (final controller in _workspaceLifecycles()) {
        controller.handleAppPaused();
      }
      return;
    }

    for (final instance in _serverInstances.values) {
      instance.access.handleAppResumed();
    }
    if (keepSessionWarmOnSwitchAway) {
      // Only the visible desktop workspace may reclaim terminal primary/theme.
      // Background workspaces stay connected but remain non-foreground.
      final activeId = servers.activeId;
      final activeController = activeId == null
          ? null
          : _workspaces.lifecycleForServer(activeId);
      activeController?.handleAppResumed();
    } else {
      for (final controller in _workspaceLifecycles()) {
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
    for (final instance in _workspaces.instances) {
      _applyTerminalPaletteTo(
        instance.connection,
        fg: palette.foregroundWire,
        bg: palette.backgroundWire,
        theme: palette.theme,
      );
    }
  }

  Iterable<WorkspaceLifecycleController> _workspaceLifecycles() =>
      _workspaces.lifecycles;

  void _setForegroundWorkspace(WorkspaceInstance foreground) {
    for (final instance in _workspaces.instances) {
      instance.lifecycle.setForeground(identical(instance, foreground));
    }
  }

  void _applyTerminalPaletteTo(
    WorkspaceConnectionController connection, {
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
    connection.setTerminalPalette(fg: fg, bg: bg, theme: theme);
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

  Future<void> registerForPush({String? serverId}) =>
      _pushCoordinator.registerForPush(serverId: serverId);

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
    await serverInstance(server.id).access.connect(force: force);
  }

  Future<bool> connectServerAndRefresh(
    String serverId, {
    bool force = false,
    bool makeActive = true,
  }) async {
    await connectServer(serverId, force: force, makeActive: makeActive);
    final runtime = existingServerInstance(serverId);
    return runtime?.access.isReady ?? false;
  }

  /// Join an existing connection attempt for [serverId], or start one. The
  /// server runtime node coalesces non-forced requests and settles every API
  /// waiter when that one state transition completes.
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
    return connectServerAndRefresh(
      serverId,
      force: force,
      makeActive: makeActive,
    );
  }

  Future<void> disconnectServer(String serverId) async {
    final runtime = existingServerInstance(serverId);
    if (runtime == null) return;
    final controllers = _workspaces.lifecyclesForServer(serverId).toList();
    await Future.wait([
      runtime.close(),
      for (final controller in controllers) controller.disconnect(),
    ]);
  }

  Future<void> refreshConnectedSessions() async {
    await Future.wait([
      for (final instance in _serverInstances.values)
        if (instance.isLive) _refreshServerCatalog(instance),
    ]);
  }

  Future<void> refreshServerSessions(String serverId) async {
    final instance = existingServerInstance(serverId);
    if (instance == null || !instance.isLive) return;
    await _refreshServerCatalog(instance);
  }

  Future<void> _refreshServerCatalog(ServerInstance instance) async {
    await instance.access.refreshSessions();
  }

  void _pruneInstancesForDeletedServers() {
    final liveIds = {for (final server in servers.servers) server.id};
    unawaited(push.retainInstanceServers(liveIds));
    for (final instance in _workspaces.removeDeletedServers(liveIds)) {
      unawaited(instance.closeAndDispose());
    }
    for (final id in _serverInstances.keys.toList()) {
      if (liveIds.contains(id)) continue;
      final instance = _serverInstances.remove(id)!;
      _pushCoordinator.removeServer(id);
      unawaited(instance.close().whenComplete(instance.dispose));
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _serversSubscription.dispose();
    _pushSubscription.dispose();
    _runtime.dispose();
    _pushCoordinator.dispose();
    _embeddedServerSubscription?.dispose();
    embeddedServer?.dispose();
    _terminalSettingsSubscription.dispose();
    _tailscaleSubscription.dispose();
    platform.tailscale.dispose();
    _lifecycleListener?.dispose();
    for (final instance in _workspaces.instances) {
      instance.dispose();
    }
    for (final instance in _serverInstances.values) {
      instance.dispose();
    }
    _serverInstances.clear();
  }
}
