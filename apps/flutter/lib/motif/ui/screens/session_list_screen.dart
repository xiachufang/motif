import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../platform/window_title.dart';
import '../../state/app/app_state.dart';
import '../../state/connection/connection_state.dart';
import '../../state/app/motif_scope.dart';
import '../../state/server/server_view_models.dart';
import '../../state/server/session_catalog_controller.dart';
import '../../state/workspace/workspace_api.dart';
import '../app.dart';
import '../theme/motif_theme.dart';
import '../widgets/connection_details_dialog.dart';
import '../widgets/motif_form.dart';
import '../widgets/motif_status_badge.dart';
import '../widgets/observation_select.dart';
import '../widgets/tailscale_section.dart';
import '../widgets/top_toast.dart';
import 'create_session_dialog.dart';
import 'rzv_pairing_sheet.dart';
import 'server_edit_sheet.dart';
import 'session_list_settings_sheet.dart';
import 'session_screen.dart';

part 'session_list_screen.g.dart';

/// Root screen after servers are configured: grouped session picker for all
/// manually connected servers.
class SessionListScreen extends StatefulWidget {
  const SessionListScreen({super.key});

  /// Human-friendly age from an epoch-seconds (or ms) timestamp.
  static String relativeTime(int ts) {
    final ms = ts > 100000000000 ? ts : ts * 1000; // accept s or ms
    final d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms),
    );
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen>
    with RouteAware, WidgetsBindingObserver {
  Future<void>? _refreshAllFuture;
  ModalRoute<void>? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncWindowTitle();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _route)) return;
    if (_route != null) motifRouteObserver.unsubscribe(this);
    _route = route;
    motifRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    _syncWindowTitle();
    unawaited(_refreshAll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshAll());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    motifRouteObserver.unsubscribe(this);
    super.dispose();
  }

  Future<void> _refreshAll() {
    final existing = _refreshAllFuture;
    if (existing != null) return existing;
    final future = _refreshAllImpl();
    _refreshAllFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_refreshAllFuture, future)) {
          _refreshAllFuture = null;
        }
      }),
    );
    return future;
  }

  void _syncWindowTitle() {
    unawaited(MotifWindowTitle.set('Motif').catchError((_) {}));
  }

  Future<void> _refreshAllImpl() async {
    await Future.wait([
      readObservationScope<AppState>(context).refreshConnectedSessions(),
      // Keep the pull-to-refresh affordance visible even when RPC returns
      // immediately, so the gesture has clear feedback.
      Future<void>.delayed(const Duration(milliseconds: 250)),
    ]);
  }

  Future<void> _addAndConnectServer() async {
    final result = await showServerEditSheet(context, connectOnSave: true);
    if (result == null || !result.connectAfterSave) return;
    await _connectServer(result.server);
  }

  Future<void> _pairAndConnectServer() async {
    final id = await showRzvPairingSheet(context);
    if (id == null || !mounted) return;
    final server = readObservationScope<AppState>(context).serverById(id);
    if (server == null) return;
    await _connectServer(server);
  }

  Future<void> _connectServer(MotifServer server) async {
    final app = readObservationScope<AppState>(context);
    await app.connectServerAndRefresh(server.id, force: true);
    if (mounted &&
        app.serverViewState(server.id).primaryAction ==
            ServerConnectionAction.setupTransport) {
      await _setupTransport(server);
    }
  }

  Future<void> _setupTransport(MotifServer server) async {
    if (!mounted) return;
    switch (server.kind) {
      case ServerKind.tailscale:
        showTailscaleConnectionSheet(context);
        return;
      case ServerKind.ssh:
      case ServerKind.wsl:
        await showServerEditSheet(context, existing: server);
        return;
      case ServerKind.rendezvous:
        await _pairAndConnectServer();
        return;
      case ServerKind.direct:
        return;
    }
  }

  @override
  Widget build(BuildContext context) => ObservationSelect<Object?>(
    selector: () => null,
    builder: (context, _, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final app = ObservationScope.of<AppState>(context);
    final groups = app.connectedServerCapabilities;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Settings',
            onPressed: () => showSessionListSettingsSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.dns_outlined),
            tooltip: 'Servers',
            onPressed: () => openConnectionManager(context),
          ),
        ],
        // actionsPadding: const EdgeInsets.only(right: MotifSpacing.xs),
      ),
      body: RefreshIndicator(
        triggerMode: RefreshIndicatorTriggerMode.anywhere,
        onRefresh: _refreshAll,
        child: groups.isEmpty
            ? _SessionListEmptyState(
                key: const ValueKey('session-list-empty'),
                app: app,
                onAddServer: _addAndConnectServer,
                onPairServer: _pairAndConnectServer,
                onConnectServer: _connectServer,
                onSetupTransport: _setupTransport,
              )
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  MotifSpacing.lg,
                  MotifSpacing.md,
                  MotifSpacing.lg,
                  MotifSpacing.xl,
                ),
                itemCount: groups.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: MotifSpacing.xl),
                itemBuilder: (context, index) {
                  final group = groups[index];
                  return _ServerSessionSection(
                    key: ValueKey(group.viewModel.id),
                    server: group.viewModel,
                    sessions: group.sessions,
                    workspace: group.workspace,
                    isLive: group.isLive,
                    viewState: app.serverViewState(group.viewModel.id),
                    onRefresh: () =>
                        app.refreshServerSessions(group.viewModel.id),
                    onAttach: (session) =>
                        _attach(context, app, group.viewModel.profile, session),
                    onDestroy: (session) =>
                        app.destroySession(group.viewModel.id, session),
                  );
                },
              ),
      ),
    );
  }

  void _attach(
    BuildContext context,
    AppState app,
    MotifServer server,
    String name,
  ) {
    // Navigate immediately; SessionScreen performs the attach itself and shows
    // a connecting overlay, so opening a session never blocks on the network.
    unawaited(app.servers.setActive(server.id));
    app.workspaceForSession(server.id, name);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: sessionRouteName(server.id, name)),
        builder: (_) => SessionScreen(serverId: server.id, session: name),
      ),
    );
  }
}

@ObservationWidget()
class _ServerSessionSection extends _$_ServerSessionSection {
  final ServerViewModel server;
  final SessionCatalogController sessions;
  final WorkspaceApi workspace;
  final bool isLive;
  final ServerConnectionViewState viewState;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onAttach;
  final Future<void> Function(String session) onDestroy;

  const _ServerSessionSection({
    required this.server,
    required this.sessions,
    required this.workspace,
    required this.isLive,
    required this.viewState,
    required this.onRefresh,
    required this.onAttach,
    required this.onDestroy,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return MotifSection(
      title: server.profile.name,
      headerTrailing: _ServerHeaderActions(
        key: ValueKey('server-header-actions-${server.id}'),
        isLive: isLive,
        viewState: viewState,
        serverId: server.id,
        serverName: server.profile.name,
        onRefresh: onRefresh,
      ),
      children: [
        _CreateSessionRow(
          onPressed: isLive
              ? () => createSessionWithDialog(context, sessions, workspace)
              : null,
        ),
        if (server.sessions.sessions.isEmpty)
          const MotifSectionRow(
            title: 'No sessions yet',
            subtitle: 'Create a session on this server.',
            titleWeight: FontWeight.w400,
          )
        else
          for (final session in server.sessions.sessions)
            _SessionRow(
              serverId: server.id,
              session: session,
              onAttach: () => onAttach(session.name),
              onDestroy: () => onDestroy(session.name),
            ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final String serverId;
  final SessionInfo session;
  final VoidCallback onAttach;
  final Future<void> Function() onDestroy;

  const _SessionRow({
    required this.serverId,
    required this.session,
    required this.onAttach,
    required this.onDestroy,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final clients = session.clientCount ?? 0;
    return Dismissible(
      key: ValueKey('session-$serverId-${session.name}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: c.danger,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: MotifSpacing.lg),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDestroy(context, session.name),
      onDismissed: (_) => unawaited(_destroySession(context)),
      child: InkWell(
        onTap: onAttach,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MotifSpacing.lg,
            vertical: MotifSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MotifType.body.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (session.workdir != null &&
                        session.workdir!.isNotEmpty) ...[
                      const SizedBox(height: MotifSpacing.xs),
                      Row(
                        children: [
                          Icon(
                            Icons.folder_outlined,
                            size: 11,
                            color: c.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              session.workdir!,
                              overflow: TextOverflow.ellipsis,
                              style: MotifType.monoSmall.copyWith(
                                color: c.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: MotifSpacing.xs),
                    Row(
                      children: [
                        if (clients > 0) ...[
                          Icon(Icons.group, size: 12, color: c.accent),
                          const SizedBox(width: 4),
                          Text(
                            '$clients attached',
                            style: MotifType.micro.copyWith(
                              color: c.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        if (session.createdAt != null)
                          Text(
                            SessionListScreen.relativeTime(session.createdAt!),
                            style: MotifType.micro.copyWith(
                              color: c.textTertiary,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: MotifSpacing.sm),
              Icon(Icons.chevron_right, color: c.textTertiary, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmDestroy(BuildContext context, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Destroy "$name"?'),
        content: const Text(
          'This kills the session and its terminals on the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Destroy'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _destroySession(BuildContext context) async {
    // This row is removed synchronously by WorkspaceConnectionController's optimistic update, so
    // retain the root Overlay's stable context for reporting an async failure.
    final toastContext = Overlay.of(context, rootOverlay: true).context;
    try {
      await onDestroy();
    } catch (e) {
      if (toastContext.mounted) {
        showMotifToast(toastContext, 'Destroy failed: $e');
      }
    }
  }
}

class _CreateSessionRow extends StatelessWidget {
  final VoidCallback? onPressed;

  const _CreateSessionRow({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final enabled = onPressed != null;
    final color = enabled ? c.accent : c.textTertiary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MotifSpacing.lg,
            vertical: MotifSpacing.md,
          ),
          child: Row(
            children: [
              Icon(Icons.add_circle, color: color, size: MotifIconSize.md),
              const SizedBox(width: MotifSpacing.md),
              Expanded(
                child: Text(
                  'Create session',
                  style: MotifType.body.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final ServerConnectionViewState viewState;
  const _StatusChip({required this.viewState});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.sm),
      child: MotifStatusBadge(
        label: viewState.statusLabel,
        color: _toneColor(c, viewState.tone),
        labelColor: c.textSecondary,
      ),
    );
  }
}

@ObservableModel()
class _ServerHeaderActionsViewModel extends _$_ServerHeaderActionsViewModel {
  _ServerHeaderActionsViewModel({bool refreshing = false}) : super(refreshing);
}

@ObservationWidget()
class _ServerHeaderActions extends _$_ServerHeaderActions {
  final bool isLive;
  final ServerConnectionViewState viewState;
  final String serverId;
  final String serverName;
  final Future<void> Function() onRefresh;

  const _ServerHeaderActions({
    required this.isLive,
    required this.viewState,
    required this.serverId,
    required this.serverName,
    required this.onRefresh,
    super.key,
  });

  @ObservableState(name: 'viewModel')
  _ServerHeaderActionsViewModel createViewModel() =>
      _ServerHeaderActionsViewModel();

  Future<void> _refresh(_ServerHeaderActionsViewModel viewModel) async {
    if (viewModel.refreshing) return;
    viewModel.refreshing = true;
    try {
      await onRefresh();
    } finally {
      viewModel.refreshing = false;
    }
  }

  @override
  Widget build(
    BuildContext context, {
    required _ServerHeaderActionsViewModel viewModel,
  }) {
    final c = context.motif;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusChip(viewState: viewState),
        IconButton(
          key: ValueKey('refresh-server-sessions-$serverId'),
          icon: viewModel.refreshing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          tooltip: 'Refresh $serverName sessions',
          visualDensity: VisualDensity.compact,
          // IconButton.color routes through styleFrom(foregroundColor:), which
          // regenerates a
          // non-transparent overlayColor that overrides the theme's transparent
          // one — re-adding the hover circle. iconButtonStyle() keeps the
          // theme's transparent overlay and just swaps the foreground.
          style: context.iconButtonStyle(foregroundColor: c.textSecondary),
          onPressed: isLive && !viewModel.refreshing
              ? () => unawaited(_refresh(viewModel))
              : null,
        ),
      ],
    );
  }
}

@ObservationWidget()
class _SessionListEmptyState extends _$_SessionListEmptyState {
  final AppState app;
  final Future<void> Function() onAddServer;
  final Future<void> Function() onPairServer;
  final Future<void> Function(MotifServer server) onConnectServer;
  final Future<void> Function(MotifServer server) onSetupTransport;

  const _SessionListEmptyState({
    required this.app,
    required this.onAddServer,
    required this.onPairServer,
    required this.onConnectServer,
    required this.onSetupTransport,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final servers = app.servers.servers;
    final active = app.servers.activeServer ?? servers.firstOrNull;
    final view = active == null ? null : app.serverViewState(active.id);
    final action = view?.primaryAction ?? ServerConnectionAction.none;
    final connecting = view?.showSpinner ?? false;
    final connectionFailed = view?.tone == ServerConnectionTone.danger;
    final showDetails = view != null && hasConnectionDetails(view);
    final transportSetupNeeded =
        action == ServerConnectionAction.setupTransport;
    final title = active == null
        ? 'No servers configured'
        : transportSetupNeeded
        ? view?.statusLabel ?? 'Reach via setup needed'
        : connecting
        ? 'Connecting to ${active.name}'
        : connectionFailed
        ? view?.statusLabel ?? 'Connection failed'
        : 'No connected servers';
    final subtitle = active == null
        ? 'Connect a motifd server to load sessions.'
        : transportSetupNeeded
        ? (view?.subtitle.split('\n').last ??
              'Set up reach via for ${active.name}.')
        : connectionFailed
        ? connectionStatusSummary(view, fallback: 'Connection failed')
        : 'Connect ${active.name} to load its sessions.';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 96),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.xl),
            child: Column(
              children: [
                Icon(Icons.dns_outlined, size: 44, color: c.textTertiary),
                const SizedBox(height: MotifSpacing.md),
                Text(
                  title,
                  style: MotifType.title.copyWith(color: c.textPrimary),
                ),
                const SizedBox(height: MotifSpacing.xs),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: MotifType.subhead.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: MotifSpacing.lg),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: MotifSpacing.md,
                  children: [
                    FilledButton.icon(
                      onPressed:
                          connecting || action == ServerConnectionAction.none
                          ? null
                          : active == null
                          ? () => unawaited(onAddServer())
                          : () => _performAction(context, active, action),
                      icon: Icon(
                        active == null
                            ? Icons.dns_outlined
                            : transportSetupNeeded
                            ? Icons.tune
                            : Icons.cloud_sync_outlined,
                      ),
                      label: Text(
                        active == null
                            ? 'Connect a Server'
                            : transportSetupNeeded
                            ? 'Setup Reach Via'
                            : connecting
                            ? 'Connecting…'
                            : connectionFailed
                            ? 'Retry ${active.name}'
                            : 'Connect ${active.name}',
                      ),
                    ),
                    if (showDetails && active != null)
                      OutlinedButton.icon(
                        onPressed: () => unawaited(
                          showConnectionDetailsDialog(
                            context,
                            title: '${active.name}: ${view.statusLabel}',
                            detail: view.subtitle,
                          ),
                        ),
                        icon: const Icon(Icons.info_outline),
                        label: const Text('Details'),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(onPairServer()),
                      icon: const Icon(Icons.qr_code_2),
                      label: const Text('Pair with Link'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => openConnectionManager(context),
                      icon: const Icon(Icons.tune),
                      label: const Text('Manage Servers'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _performAction(
    BuildContext context,
    MotifServer server,
    ServerConnectionAction action,
  ) {
    switch (action) {
      case ServerConnectionAction.none:
      case ServerConnectionAction.disconnect:
      case ServerConnectionAction.openSessions:
        return;
      case ServerConnectionAction.setupTransport:
        unawaited(onSetupTransport(server));
        return;
      case ServerConnectionAction.connect:
      case ServerConnectionAction.retry:
        unawaited(onConnectServer(server));
        return;
    }
  }
}

Color _toneColor(MotifColors c, ServerConnectionTone tone) {
  return switch (tone) {
    ServerConnectionTone.neutral => c.textSecondary,
    ServerConnectionTone.accent => c.accent,
    ServerConnectionTone.success => c.success,
    ServerConnectionTone.warning => c.warning,
    ServerConnectionTone.danger => c.danger,
  };
}
