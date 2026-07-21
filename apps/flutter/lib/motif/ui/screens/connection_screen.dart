import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../models/settings.dart';
import '../../net/rpc_client.dart';
import '../../platform/services.dart';
import '../../platform/tailscale_support.dart';
import '../../state/app/app_state.dart';
import '../../state/connection/connection_state.dart';
import '../../state/app/motif_scope.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/connection_details_dialog.dart';
import '../widgets/motif_form.dart';
import '../widgets/motif_status_badge.dart';
import '../widgets/tailscale_section.dart';
import 'rzv_pairing_sheet.dart';
import 'server_edit_sheet.dart';

part 'connection_screen.g.dart';

/// Server list + management (mirrors ConnectionView).
@ObservationWidget()
class ConnectionScreen extends _$ConnectionScreen {
  const ConnectionScreen({super.key});

  Future<void> _addServer(
    BuildContext context,
    AppState app, {
    ServerKind? initialKind,
  }) async {
    final result = await showServerEditSheet(
      context,
      initialKind: initialKind,
      connectOnSave: true,
    );
    if (result == null || !result.connectAfterSave) return;
    if (!context.mounted) return;
    await _connectServer(context, app, result.server);
  }

  /// Pair a rendezvous server from a scanned/pasted `motif://pair` link, then
  /// connect to it.
  Future<void> _pairServer(BuildContext context, AppState app) async {
    final id = await showRzvPairingSheet(context);
    if (id == null || !context.mounted) return;
    final server = app.serverById(id);
    if (server == null) return;
    await _connectServer(context, app, server);
  }

  Future<void> _connectServer(
    BuildContext context,
    AppState app,
    MotifServer server,
  ) async {
    await app.connectServerAndRefresh(server.id, force: true, makeActive: true);
    if (context.mounted &&
        app.serverViewState(server.id).primaryAction ==
            ServerConnectionAction.setupTransport) {
      _setupTransport(context, app, server);
    }
  }

  void _openSessions(BuildContext context) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  void _performServerAction(
    BuildContext context,
    AppState app,
    MotifServer server,
    ServerConnectionAction action,
  ) {
    switch (action) {
      case ServerConnectionAction.none:
        return;
      case ServerConnectionAction.connect:
      case ServerConnectionAction.retry:
        unawaited(_connectServer(context, app, server));
        return;
      case ServerConnectionAction.disconnect:
        unawaited(app.disconnectServer(server.id));
        return;
      case ServerConnectionAction.setupTransport:
        _setupTransport(context, app, server);
        return;
      case ServerConnectionAction.openSessions:
        _openSessions(context);
        return;
    }
  }

  void _setupTransport(BuildContext context, AppState app, MotifServer server) {
    switch (server.kind) {
      case ServerKind.tailscale:
        if (tailscaleSupported) showTailscaleConnectionSheet(context);
        return;
      case ServerKind.ssh:
      case ServerKind.wsl:
        unawaited(showServerEditSheet(context, existing: server));
        return;
      case ServerKind.rendezvous:
        unawaited(_pairServer(context, app));
        return;
      case ServerKind.direct:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Scaffold(
      backgroundColor: c.background,
      appBar: const AdaptiveModalHeader(title: 'Connection'),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final app = ObservationScope.of<AppState>(context);
    final c = context.motif;
    final servers = app.servers.servers;
    return SafeArea(
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(
          MotifSpacing.lg,
          MotifSpacing.md,
          MotifSpacing.lg,
          MotifSpacing.xl,
        ),
        children: [
          MotifSection(
            title: 'Servers',
            headerTrailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.qr_code_2),
                  tooltip: 'Pair with link',
                  onPressed: () => unawaited(_pairServer(context, app)),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add Server',
                  onPressed: () => unawaited(_addServer(context, app)),
                ),
              ],
            ),
            children: servers.isEmpty
                ? [
                    MotifSectionRow(
                      title: 'No servers configured. Tap + to add one.',
                      titleColor: c.textSecondary,
                      titleWeight: FontWeight.w400,
                    ),
                  ]
                : [
                    for (final s in servers)
                      _ServerRow(
                        key: ValueKey('server-row-state-${s.id}'),
                        server: s,
                        viewState: app.serverViewState(s.id),
                        onAction: (action) =>
                            _performServerAction(context, app, s, action),
                        onEdit: () => showServerEditSheet(context, existing: s),
                        onDelete: () {
                          unawaited(app.disconnectServer(s.id));
                          unawaited(app.servers.delete(s.id));
                        },
                      ),
                  ],
          ),
        ],
      ),
    );
  }
}

class ConnectionPanel extends ConnectionScreen {
  const ConnectionPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return AdaptivePanel(title: 'Connection', body: _buildBody(context));
  }
}

@ObservableModel()
class _ServerRowViewModel extends _$_ServerRowViewModel {
  _ServerRowViewModel({
    _ServerPingIndicator pingIndicator = _ServerPingIndicator.idle,
  }) : super(pingIndicator);
}

final class _ServerPingCoordinator {
  TailscaleService? tailscale;
  String? lastPingKey;
  int generation = 0;
  bool disposed = false;

  void dispose() {
    disposed = true;
    generation++;
  }
}

@ObservationWidget()
class _ServerRow extends _$_ServerRow {
  final MotifServer server;
  final ServerConnectionViewState viewState;
  final ValueChanged<ServerConnectionAction> onAction;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ServerRow({
    required this.server,
    required this.viewState,
    required this.onAction,
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  @ObservableState(name: 'viewModel')
  _ServerRowViewModel createViewModel() => _ServerRowViewModel();

  @PlainState(name: 'coordinator')
  _ServerPingCoordinator createCoordinator() => _ServerPingCoordinator();

  String _pingKey(_ServerPingCoordinator coordinator) {
    final tailscaleStatus = server.kind == ServerKind.tailscale
        ? (coordinator.tailscale?.state.status.name ?? 'unknown')
        : 'n/a';
    return '${server.id}|${server.host}|${server.port}|${server.kind.name}|$tailscaleStatus';
  }

  void _schedulePingRefresh(
    BuildContext context,
    _ServerRowViewModel viewModel,
    _ServerPingCoordinator coordinator,
  ) {
    final key = _pingKey(coordinator);
    if (key == coordinator.lastPingKey) return;
    coordinator.lastPingKey = key;
    Future.microtask(() {
      if (context.mounted && !coordinator.disposed) {
        unawaited(_refreshPingIndicator(context, viewModel, coordinator));
      }
    });
  }

  Future<void> _refreshPingIndicator(
    BuildContext context,
    _ServerRowViewModel viewModel,
    _ServerPingCoordinator coordinator,
  ) async {
    final tailscale =
        coordinator.tailscale ??
        readObservationScope<AppState>(context).platform.tailscale;
    final generation = ++coordinator.generation;

    _setPingIndicator(viewModel, coordinator, _ServerPingIndicator.checking);
    final result = switch (server.kind) {
      ServerKind.tailscale => await _pingTailscaleServer(tailscale, server),
      ServerKind.ssh => _ServerPingIndicator.unavailable('Via SSH'),
      ServerKind.wsl => _ServerPingIndicator.unavailable('Via WSL'),
      ServerKind.rendezvous ||
      ServerKind.direct => await _pingDirectServer(server),
    };
    if (!context.mounted ||
        coordinator.disposed ||
        generation != coordinator.generation) {
      return;
    }
    _setPingIndicator(viewModel, coordinator, result);
  }

  void _setPingIndicator(
    _ServerRowViewModel viewModel,
    _ServerPingCoordinator coordinator,
    _ServerPingIndicator indicator,
  ) {
    if (coordinator.disposed || viewModel.pingIndicator == indicator) return;
    viewModel.pingIndicator = indicator;
  }

  Future<_ServerPingIndicator> _pingTailscaleServer(
    TailscaleService tailscale,
    MotifServer server,
  ) async {
    if (tailscale.state.status != TailscaleStatus.running) {
      return _ServerPingIndicator.unavailable('Tailscale off');
    }
    final result = await tailscale.pingMotifServer(
      host: server.host,
      port: server.port,
    );
    return _ServerPingIndicator.fromReachability(
      reachable: result.reachable,
      version: result.version,
      message: result.message,
    );
  }

  Future<_ServerPingIndicator> _pingDirectServer(MotifServer server) async {
    final rpc = RpcClient()
      ..connect(host: server.host, port: server.port, token: server.token);
    try {
      final ping = await rpc.ping().timeout(const Duration(seconds: 5));
      if (!ping.isMotifServer) {
        return _ServerPingIndicator.unreachable('Not motifd');
      }
      return _ServerPingIndicator.reachable(ping.version);
    } on TimeoutException {
      return _ServerPingIndicator.unreachable('No response');
    } on RpcException catch (e) {
      return _ServerPingIndicator.unreachable(e.message);
    } catch (_) {
      return _ServerPingIndicator.unreachable('Ping failed');
    } finally {
      await rpc.close();
    }
  }

  @override
  Widget build(
    BuildContext context, {
    required _ServerRowViewModel viewModel,
    required _ServerPingCoordinator coordinator,
  }) {
    final tailscale = ObservationScope.of<AppState>(context).platform.tailscale;
    if (!identical(coordinator.tailscale, tailscale)) {
      coordinator
        ..tailscale = tailscale
        ..lastPingKey = null;
    }
    final _ = tailscale.state;
    _schedulePingRefresh(context, viewModel, coordinator);
    final c = context.motif;
    final view = viewState;
    final pingIndicator = viewModel.pingIndicator;
    final action = view.primaryAction;
    final showPingBadge =
        view.statusLabel == 'Offline' &&
        pingIndicator.kind == _ServerPingIndicatorKind.reachable;
    final showDetails = hasConnectionDetails(view);
    return MotifSectionRow(
      key: ValueKey('server-row-${server.id}'),
      leading: Icon(
        _iconForViewState(view),
        key: ValueKey('server-kind-icon-${server.id}'),
        color: _toneColor(c, view.tone),
        size: 18,
      ),
      title: server.name,
      subtitle: view.subtitle,
      titleWeight: view.canOpenSessions ? FontWeight.w700 : FontWeight.w500,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showPingBadge)
            _ServerPingBadge(indicator: pingIndicator)
          else
            _ServerConnectionBadge(viewState: view),
          if (showDetails) ...[
            const SizedBox(width: MotifSpacing.xs),
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: 'Show connection details',
              onPressed: () => unawaited(
                showConnectionDetailsDialog(
                  context,
                  title: '${server.name}: ${view.statusLabel}',
                  detail: view.subtitle,
                ),
              ),
            ),
          ],
          const SizedBox(width: MotifSpacing.sm),
          if (action != ServerConnectionAction.none)
            IconButton(
              icon: Icon(_iconForAction(action)),
              tooltip: _tooltipForAction(action),
              onPressed: () => onAction(action),
            ),
          PopupMenuButton<String>(
            // Keep the trigger free of the regenerated hover overlay (see note
            // in motif_theme.dart: PopupMenuButton(icon:) path).
            style: motifNoButtonFeedback,
            tooltip: 'Server actions',
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  onEdit();
                  break;
                case 'delete':
                  onDelete();
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Edit'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Delete'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: view.tapAction == ServerConnectionAction.none
          ? null
          : () => onAction(view.tapAction),
    );
  }
}

IconData _iconForViewState(ServerConnectionViewState viewState) {
  return switch (viewState.icon) {
    ServerConnectionIconKind.direct => Icons.public,
    ServerConnectionIconKind.tailscale => Icons.hub_outlined,
    ServerConnectionIconKind.rendezvous => Icons.cell_tower_outlined,
    ServerConnectionIconKind.ssh => Icons.key_outlined,
    ServerConnectionIconKind.wsl => Icons.developer_mode_outlined,
    ServerConnectionIconKind.sync => Icons.cloud_sync_outlined,
    ServerConnectionIconKind.warning => Icons.warning_rounded,
    ServerConnectionIconKind.offline => Icons.cloud_off_outlined,
  };
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

IconData _iconForAction(ServerConnectionAction action) {
  return switch (action) {
    ServerConnectionAction.connect => Icons.cloud_sync_outlined,
    ServerConnectionAction.retry => Icons.refresh,
    ServerConnectionAction.disconnect => Icons.link_off_outlined,
    ServerConnectionAction.setupTransport => Icons.tune,
    ServerConnectionAction.openSessions => Icons.terminal,
    ServerConnectionAction.none => Icons.circle_outlined,
  };
}

String _tooltipForAction(ServerConnectionAction action) {
  return switch (action) {
    ServerConnectionAction.connect => 'Connect Server',
    ServerConnectionAction.retry => 'Retry Connection',
    ServerConnectionAction.disconnect => 'Disconnect Server',
    ServerConnectionAction.setupTransport => 'Setup Reach Via',
    ServerConnectionAction.openSessions => 'Open Sessions',
    ServerConnectionAction.none => '',
  };
}

enum _ServerPingIndicatorKind {
  idle,
  checking,
  reachable,
  unreachable,
  unavailable,
}

class _ServerPingIndicator {
  final _ServerPingIndicatorKind kind;
  final String message;
  final String? version;

  const _ServerPingIndicator._(this.kind, {this.message = '', this.version});

  static const idle = _ServerPingIndicator._(_ServerPingIndicatorKind.idle);
  static const checking = _ServerPingIndicator._(
    _ServerPingIndicatorKind.checking,
  );

  static _ServerPingIndicator unavailable(String message) =>
      _ServerPingIndicator._(
        _ServerPingIndicatorKind.unavailable,
        message: message,
      );

  static _ServerPingIndicator reachable(String? version) =>
      _ServerPingIndicator._(
        _ServerPingIndicatorKind.reachable,
        version: version,
      );

  static _ServerPingIndicator unreachable(String message) =>
      _ServerPingIndicator._(
        _ServerPingIndicatorKind.unreachable,
        message: message,
      );

  static _ServerPingIndicator fromReachability({
    required bool reachable,
    String? version,
    required String message,
  }) {
    return reachable
        ? _ServerPingIndicator.reachable(version)
        : _ServerPingIndicator.unreachable(message);
  }

  String get label => switch (kind) {
    _ServerPingIndicatorKind.idle ||
    _ServerPingIndicatorKind.checking => 'Checking',
    _ServerPingIndicatorKind.reachable => 'Reachable',
    _ServerPingIndicatorKind.unreachable => 'No ping',
    _ServerPingIndicatorKind.unavailable => message,
  };

  String get accessibilityValue => switch (kind) {
    _ServerPingIndicatorKind.reachable =>
      version == null || version!.isEmpty ? 'Reachable' : 'motifd $version',
    _ServerPingIndicatorKind.unreachable => message,
    _ => label,
  };

  @override
  bool operator ==(Object other) =>
      other is _ServerPingIndicator &&
      other.kind == kind &&
      other.message == message &&
      other.version == version;

  @override
  int get hashCode => Object.hash(kind, message, version);
}

class _ServerPingBadge extends StatelessWidget {
  final _ServerPingIndicator indicator;

  const _ServerPingBadge({required this.indicator});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final color = switch (indicator.kind) {
      _ServerPingIndicatorKind.reachable => c.success,
      _ServerPingIndicatorKind.unreachable => c.danger,
      _ServerPingIndicatorKind.unavailable ||
      _ServerPingIndicatorKind.idle ||
      _ServerPingIndicatorKind.checking => c.textSecondary,
    };
    final icon = switch (indicator.kind) {
      _ServerPingIndicatorKind.reachable => Icons.check_circle,
      _ServerPingIndicatorKind.unreachable => Icons.cancel,
      _ServerPingIndicatorKind.unavailable => Icons.remove_circle,
      _ServerPingIndicatorKind.idle ||
      _ServerPingIndicatorKind.checking => Icons.circle_outlined,
    };
    final busy =
        indicator.kind == _ServerPingIndicatorKind.idle ||
        indicator.kind == _ServerPingIndicatorKind.checking;

    return Semantics(
      label: 'Server ping',
      value: indicator.accessibilityValue,
      child: MotifStatusBadge(
        label: indicator.label,
        color: color,
        icon: busy ? null : icon,
        busy: busy,
      ),
    );
  }
}

class _ServerConnectionBadge extends StatelessWidget {
  final ServerConnectionViewState viewState;

  const _ServerConnectionBadge({required this.viewState});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final color = _toneColor(c, viewState.tone);
    return Tooltip(
      message: viewState.subtitle,
      child: Semantics(
        label: 'Server connection',
        value: '${viewState.statusLabel}\n${viewState.subtitle}',
        child: MotifStatusBadge(
          label: viewState.statusLabel,
          color: color,
          icon: viewState.showSpinner ? null : _iconForViewState(viewState),
          busy: viewState.showSpinner,
        ),
      ),
    );
  }
}
