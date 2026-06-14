import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/settings.dart';
import '../../net/rpc_client.dart';
import '../../platform/services.dart';
import '../../platform/tailscale_support.dart';
import '../../state/app_state.dart';
import '../../state/connection_state.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/tailscale_section.dart';
import 'rzv_pairing_sheet.dart';
import 'server_edit_sheet.dart';

/// Server list + management (mirrors ConnectionView).
class ConnectionScreen extends StatelessWidget {
  const ConnectionScreen({super.key});

  Future<void> _addServer(BuildContext context, AppState app) async {
    final result = await showServerEditSheet(context, connectOnSave: true);
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
    if (tailscaleSupported &&
        context.mounted &&
        app.serverViewState(server.id).primaryAction ==
            ServerConnectionAction.openTailscale) {
      showTailscaleConnectionSheet(context);
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
      case ServerConnectionAction.disconnect:
        unawaited(app.disconnectServer(server.id));
      case ServerConnectionAction.openTailscale:
        if (!tailscaleSupported) return;
        showTailscaleConnectionSheet(context);
      case ServerConnectionAction.openSessions:
        _openSessions(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = context.motif;
    final servers = app.servers.servers;
    return Scaffold(
      backgroundColor: c.background,
      appBar: const AdaptiveModalHeader(title: 'Connection'),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            MotifSpacing.lg,
            MotifSpacing.md,
            MotifSpacing.lg,
            MotifSpacing.xl,
          ),
          children: [
            if (tailscaleSupported) ...[
              const MotifSection(
                title: 'Tailscale',
                children: [TailscaleSection()],
              ),
              const SizedBox(height: MotifSpacing.xl),
            ],
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
                          server: s,
                          viewState: app.serverViewState(s.id),
                          onAction: (action) =>
                              _performServerAction(context, app, s, action),
                          onEdit: () =>
                              showServerEditSheet(context, existing: s),
                          onDelete: () {
                            unawaited(app.disconnectServer(s.id));
                            unawaited(app.servers.delete(s.id));
                          },
                        ),
                    ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerRow extends StatefulWidget {
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
  });

  @override
  State<_ServerRow> createState() => _ServerRowState();
}

class _ServerRowState extends State<_ServerRow> {
  TailscaleService? _tailscale;
  StreamSubscription<TailscaleState>? _tailscaleSub;
  _ServerPingIndicator _pingIndicator = _ServerPingIndicator.idle;
  String? _lastPingKey;
  int _pingGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tailscale = context.read<AppState>().platform.tailscale;
    if (!identical(_tailscale, tailscale)) {
      _tailscaleSub?.cancel();
      _tailscale = tailscale;
      _lastPingKey = null;
      _tailscaleSub = tailscale.states.listen((_) {
        if (widget.server.kind == ServerKind.tailscale) {
          _schedulePingRefresh(force: true);
        }
      });
    }
    _schedulePingRefresh();
  }

  @override
  void didUpdateWidget(covariant _ServerRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server.id != widget.server.id ||
        oldWidget.server.host != widget.server.host ||
        oldWidget.server.port != widget.server.port ||
        oldWidget.server.kind != widget.server.kind) {
      _schedulePingRefresh(force: true);
    }
  }

  @override
  void dispose() {
    _pingGeneration++;
    _tailscaleSub?.cancel();
    super.dispose();
  }

  String get _pingKey {
    final server = widget.server;
    final tailscaleStatus = server.kind == ServerKind.tailscale
        ? (_tailscale?.state.status.name ?? 'unknown')
        : 'n/a';
    return '${server.id}|${server.host}|${server.port}|${server.kind.name}|$tailscaleStatus';
  }

  void _schedulePingRefresh({bool force = false}) {
    final key = _pingKey;
    if (!force && key == _lastPingKey) return;
    _lastPingKey = key;
    Future.microtask(() {
      if (mounted) _refreshPingIndicator();
    });
  }

  Future<void> _refreshPingIndicator() async {
    final server = widget.server;
    final tailscale = _tailscale ?? context.read<AppState>().platform.tailscale;
    final generation = ++_pingGeneration;

    _setPingIndicator(_ServerPingIndicator.checking);
    final result = server.kind == ServerKind.tailscale
        ? await _pingTailscaleServer(tailscale, server)
        : await _pingDirectServer(server);
    if (!mounted || generation != _pingGeneration) return;
    _setPingIndicator(result);
  }

  void _setPingIndicator(_ServerPingIndicator indicator) {
    if (_pingIndicator == indicator || !mounted) return;
    setState(() => _pingIndicator = indicator);
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
  Widget build(BuildContext context) {
    final c = context.motif;
    final view = widget.viewState;
    final action = view.primaryAction;
    final showPingBadge = view.statusLabel == 'Offline';
    return MotifSectionRow(
      leading: Icon(
        _iconForViewState(view),
        key: ValueKey('server-kind-icon-${widget.server.id}'),
        color: _toneColor(c, view.tone),
        size: 18,
      ),
      title: widget.server.name,
      subtitle: view.subtitle,
      titleWeight: view.canOpenTerminal ? FontWeight.w700 : FontWeight.w500,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showPingBadge)
            _ServerPingBadge(indicator: _pingIndicator)
          else
            _ServerConnectionBadge(viewState: view),
          const SizedBox(width: MotifSpacing.sm),
          if (action != ServerConnectionAction.none)
            IconButton(
              icon: Icon(_iconForAction(action)),
              tooltip: _tooltipForAction(action),
              onPressed: () => widget.onAction(action),
            ),
          PopupMenuButton<String>(
            tooltip: 'Server actions',
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  widget.onEdit();
                  break;
                case 'delete':
                  widget.onDelete();
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
          : () => widget.onAction(view.tapAction),
    );
  }
}

IconData _iconForViewState(ServerConnectionViewState viewState) {
  return switch (viewState.icon) {
    ServerConnectionIconKind.direct => Icons.public,
    ServerConnectionIconKind.tailscale => Icons.hub_outlined,
    ServerConnectionIconKind.rendezvous => Icons.cell_tower_outlined,
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
    ServerConnectionAction.openTailscale => Icons.shield_outlined,
    ServerConnectionAction.openSessions => Icons.terminal,
    ServerConnectionAction.none => Icons.circle_outlined,
  };
}

String _tooltipForAction(ServerConnectionAction action) {
  return switch (action) {
    ServerConnectionAction.connect => 'Connect Server',
    ServerConnectionAction.retry => 'Retry Connection',
    ServerConnectionAction.disconnect => 'Disconnect Server',
    ServerConnectionAction.openTailscale => 'Setup Tailscale',
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            indicator.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 12),
          ),
        ],
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
    return Semantics(
      label: 'Server connection',
      value: viewState.statusLabel,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (viewState.showSpinner)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(_iconForViewState(viewState), size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            viewState.statusLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
