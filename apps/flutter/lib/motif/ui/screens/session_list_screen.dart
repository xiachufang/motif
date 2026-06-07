import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../platform/window_title.dart';
import '../../state/app_state.dart';
import '../../state/connection_state.dart';
import '../../state/motif_client.dart';
import '../app.dart';
import '../theme/motif_buttons.dart';
import '../theme/motif_theme.dart';
import '../widgets/motif_form.dart';
import 'create_session_dialog.dart';
import 'server_edit_sheet.dart';
import 'session_list_settings_sheet.dart';
import 'session_screen.dart';
import '../widgets/tailscale_section.dart';

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
      context.read<AppState>().refreshConnectedSessions(),
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

  Future<void> _connectServer(MotifServer server) async {
    final app = context.read<AppState>();
    await app.connectServerAndRefresh(server.id, force: true);
    if (mounted &&
        app.serverViewState(server.id).primaryAction ==
            ServerConnectionAction.openTailscale) {
      showTailscaleConnectionSheet(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final groups = app.connectedServerClients;
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
      ),
      body: RefreshIndicator(
        triggerMode: RefreshIndicatorTriggerMode.anywhere,
        onRefresh: _refreshAll,
        child: groups.isEmpty
            ? _SessionListEmptyState(
                app: app,
                onAddServer: _addAndConnectServer,
                onConnectServer: _connectServer,
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
                    server: group.server,
                    motif: group.client,
                    viewState: app.serverViewState(group.server.id),
                    onRefresh: () => app.refreshServerSessions(group.server.id),
                    onAttach: (session) => _attach(
                      context,
                      app,
                      group.server,
                      group.client,
                      session,
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _attach(
    BuildContext context,
    AppState app,
    MotifServer server,
    MotifClient motif,
    String name,
  ) async {
    try {
      await app.servers.setActive(server.id);
      await motif.attach(name);
      if (context.mounted) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SessionScreen(serverId: server.id, session: name),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Attach failed: $e')));
      }
    }
  }
}

class _ServerSessionSection extends StatelessWidget {
  final MotifServer server;
  final MotifClient motif;
  final ServerConnectionViewState viewState;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onAttach;

  const _ServerSessionSection({
    required this.server,
    required this.motif,
    required this.viewState,
    required this.onRefresh,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    return MotifSection(
      title: server.name,
      headerTrailing: _ServerHeaderActions(
        motif: motif,
        viewState: viewState,
        serverId: server.id,
        serverName: server.name,
        onRefresh: onRefresh,
      ),
      children: [
        _CreateSessionRow(
          onPressed: motif.isLive
              ? () => createSessionWithDialog(context, motif)
              : null,
        ),
        if (motif.sessions.isEmpty)
          const MotifSectionRow(
            title: 'No sessions yet',
            subtitle: 'Create a session on this server.',
            titleWeight: FontWeight.w400,
          )
        else
          for (final session in motif.sessions)
            _SessionRow(
              serverId: server.id,
              session: session,
              motif: motif,
              onAttach: () => onAttach(session.name),
            ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final String serverId;
  final SessionInfo session;
  final MotifClient motif;
  final VoidCallback onAttach;

  const _SessionRow({
    required this.serverId,
    required this.session,
    required this.motif,
    required this.onAttach,
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
      onDismissed: (_) => unawaited(motif.destroySession(session.name)),
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
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 15,
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
                              style: TextStyle(
                                color: c.textSecondary,
                                fontFamily: 'monospace',
                                fontSize: 12,
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
                            style: TextStyle(
                              color: c.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        if (session.createdAt != null)
                          Text(
                            SessionListScreen.relativeTime(session.createdAt!),
                            style: TextStyle(
                              color: c.textTertiary,
                              fontSize: 11,
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
      builder: (_) => AlertDialog(
        title: Text('Destroy "$name"?'),
        content: const Text(
          'This kills the session and its terminals on the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Destroy'),
          ),
        ],
      ),
    );
    return ok ?? false;
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
              Icon(Icons.add_circle, color: color, size: 22),
              const SizedBox(width: MotifSpacing.md),
              Expanded(
                child: Text(
                  'Create session',
                  style: TextStyle(
                    color: color,
                    fontSize: 15,
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
    final label = viewState.statusLabel;
    final color = _toneColor(c, viewState.tone);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.sm),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: c.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ServerHeaderActions extends StatefulWidget {
  final MotifClient motif;
  final ServerConnectionViewState viewState;
  final String serverId;
  final String serverName;
  final Future<void> Function() onRefresh;

  const _ServerHeaderActions({
    required this.motif,
    required this.viewState,
    required this.serverId,
    required this.serverName,
    required this.onRefresh,
  });

  @override
  State<_ServerHeaderActions> createState() => _ServerHeaderActionsState();
}

class _ServerHeaderActionsState extends State<_ServerHeaderActions> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusChip(viewState: widget.viewState),
        IconButton(
          key: ValueKey('refresh-server-sessions-${widget.serverId}'),
          icon: _refreshing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          tooltip: 'Refresh ${widget.serverName} sessions',
          visualDensity: VisualDensity.compact,
          color: c.textSecondary,
          onPressed: widget.motif.isLive && !_refreshing
              ? () => unawaited(_refresh())
              : null,
        ),
      ],
    );
  }
}

class _SessionListEmptyState extends StatelessWidget {
  final AppState app;
  final Future<void> Function() onAddServer;
  final Future<void> Function(MotifServer server) onConnectServer;

  const _SessionListEmptyState({
    required this.app,
    required this.onAddServer,
    required this.onConnectServer,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final servers = app.servers.servers;
    final active = app.servers.activeServer ?? servers.firstOrNull;
    final view = active == null ? null : app.serverViewState(active.id);
    final action = view?.primaryAction ?? ServerConnectionAction.none;
    final connecting = view?.showSpinner ?? false;
    final tailscaleNeedsSetup = action == ServerConnectionAction.openTailscale;
    final failed = view?.statusLabel == 'Failed';
    final title = active == null
        ? 'No servers configured'
        : connecting && (view?.statusLabel.startsWith('Tailscale') ?? false)
        ? 'Connecting Tailscale…'
        : tailscaleNeedsSetup
        ? 'Tailscale is not connected'
        : connecting
        ? 'Connecting to ${active.name}'
        : failed
        ? 'Connection failed'
        : 'No connected servers';
    final subtitle = active == null
        ? 'Connect a motifd server to load sessions.'
        : connecting && (view?.statusLabel.startsWith('Tailscale') ?? false)
        ? 'Waiting for Tailscale to reach ${active.name}.'
        : tailscaleNeedsSetup
        ? 'Start Tailscale to reach ${active.name}.'
        : failed
        ? (view?.subtitle.split('\n').last ?? 'Connection failed')
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
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: MotifSpacing.xs),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: MotifSpacing.lg),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: MotifSpacing.md,
                  runSpacing: MotifSpacing.sm,
                  children: [
                    MotifButton(
                      label: active == null
                          ? 'Connect a Server'
                          : tailscaleNeedsSetup
                          ? 'Setup Tailscale'
                          : connecting
                          ? 'Connecting…'
                          : failed
                          ? 'Retry ${active.name}'
                          : 'Connect ${active.name}',
                      icon: active == null
                          ? Icons.dns_outlined
                          : tailscaleNeedsSetup
                          ? Icons.shield_outlined
                          : Icons.cloud_sync_outlined,
                      onPressed:
                          connecting || action == ServerConnectionAction.none
                          ? null
                          : active == null
                          ? () => unawaited(onAddServer())
                          : () => _performAction(context, active, action),
                    ),
                    MotifButton(
                      label: 'Manage Servers',
                      icon: Icons.tune,
                      role: MotifButtonRole.bordered,
                      onPressed: () => openConnectionManager(context),
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
      case ServerConnectionAction.openTailscale:
        showTailscaleConnectionSheet(context);
      case ServerConnectionAction.connect:
      case ServerConnectionAction.retry:
        unawaited(onConnectServer(server));
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
