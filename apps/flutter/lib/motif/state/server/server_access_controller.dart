import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../log/log.dart';
import '../../models/settings.dart';
import '../connection/connection_state.dart';
import 'server_transport.dart';
import 'server_view_models.dart';
import 'session_catalog_controller.dart';
import '../platform/tailscale_view_model.dart';
import 'transport_resolver.dart';

/// Resolves and maintains the server-scoped control channel. Workspace
/// attachment/reconnect is owned independently by Workspace lifecycle code.
final class ServerAccessController {
  static const Duration _reconnectBaseDelay = Duration(milliseconds: 500);
  static const Duration _reconnectMaxDelay = Duration(seconds: 30);

  ServerAccessController({
    required this.serverId,
    required this.serverProvider,
    required this.resolver,
    required this.transport,
    required this.sessions,
    required this.viewModel,
    this.onChanged,
  });

  final String serverId;
  final MotifServer? Function() serverProvider;
  final TransportResolver resolver;
  final ServerTransport transport;
  final SessionCatalogController sessions;
  final ServerAccessViewModel viewModel;
  final VoidCallback? onChanged;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _reconnecting = false;
  bool _wantsConnection = false;
  bool _appPaused = false;
  bool _resumeProbeRunning = false;

  bool get isLive => transport.isLive;
  bool get wantsConnection => _wantsConnection;

  ServerConnectionState get state => switch (viewModel.phase) {
    ServerAccessPhase.idle => const ServerIdle(),
    ServerAccessPhase.resolving =>
      _reconnecting
          ? ServerReconnecting(attempt: _reconnectAttempts)
          : const ServerConnecting(),
    ServerAccessPhase.ready => const ServerConnected(),
    ServerAccessPhase.blocked => ServerBlocked(
      viewModel.blocker ?? _fallbackBlocker(),
    ),
    ServerAccessPhase.failed => ServerFailed(
      viewModel.error ?? 'connection failed',
    ),
  };

  Future<void> connect({bool force = false}) async {
    _wantsConnection = true;
    _cancelReconnect();
    await _connect(force: force, reconnect: false);
  }

  Future<void> disconnect() async {
    _wantsConnection = false;
    _reconnectAttempts = 0;
    _cancelReconnect();
    await transport.close();
    await resolver.stopForwarder(serverId);
    resolver.forgetRzvDirect(serverId);
    _setIdle();
  }

  Future<void> refreshSessions() async {
    if (!isLive) return;
    try {
      await sessions.refresh();
    } catch (error, stackTrace) {
      handleRefreshFailed(error, stackTrace);
    }
  }

  void handleRefreshFailed(Object error, [StackTrace? stackTrace]) {
    if (!_wantsConnection || _appPaused) return;
    Log.w(
      'session refresh failed; reconnecting server=$serverId',
      name: 'motif.reconnect',
      error: error,
      stackTrace: stackTrace,
    );
    unawaited(
      _markConnectionLostAndReconnect('session refresh failed: $error'),
    );
  }

  void handleTailscaleState(TailscaleState _) {
    final server = serverProvider();
    if (server == null || server.kind != ServerKind.tailscale) return;
    final blocker = resolver.currentBlocker(server);
    if (blocker == null) {
      if (_wantsConnection &&
          (viewModel.phase == ServerAccessPhase.blocked ||
              viewModel.phase == ServerAccessPhase.failed)) {
        _maybeScheduleReconnect(immediate: true);
      }
      return;
    }
    _cancelReconnect();
    unawaited(transport.close());
    _setBlocked(blocker);
  }

  void handleAppPaused() {
    _appPaused = true;
    _cancelReconnect();
  }

  void handleAppResumed() {
    _appPaused = false;
    if (!_wantsConnection) return;
    final server = serverProvider();
    if (server == null) return;
    final blocker = resolver.currentBlocker(server);
    if (blocker != null) {
      _setBlocked(blocker);
      return;
    }
    if (!isLive || viewModel.phase != ServerAccessPhase.ready) {
      _maybeScheduleReconnect(immediate: true);
    } else {
      unawaited(_probeAfterResume());
    }
  }

  void dispose() {
    _cancelReconnect();
    unawaited(resolver.stopForwarder(serverId));
    resolver.forgetRzvDirect(serverId);
  }

  Future<void> _connect({required bool force, required bool reconnect}) async {
    final server = serverProvider();
    if (server == null) return;
    observationTransaction(() {
      viewModel
        ..phase = ServerAccessPhase.resolving
        ..transport = resolver.transportViewState(server)
        ..blocker = null
        ..error = null;
    });
    onChanged?.call();

    if (force || reconnect) await resolver.stopForwarder(server.id);
    final resolution = await resolver.resolve(server);
    switch (resolution) {
      case TransportBlocked(:final blocker):
        _setBlocked(blocker);
        return;
      case TransportReady(:final target, :final proxy, :final certPin):
        viewModel.resolvedEndpoint = target.endpoint;
        try {
          final ping = await transport.connect(
            target,
            force: force || reconnect,
            proxy: proxy,
            certPin: certPin,
          );
          _reconnectAttempts = 0;
          _reconnecting = false;
          _cancelReconnect();
          observationTransaction(() {
            viewModel
              ..phase = ServerAccessPhase.ready
              ..blocker = null
              ..error = null;
          });
          onChanged?.call();
          if (!kIsWeb &&
              server.kind == ServerKind.rendezvous &&
              resolver.learnRzvDirect(server, ping)) {
            _maybeScheduleReconnect(immediate: true);
          }
        } catch (error) {
          await transport.close();
          observationTransaction(() {
            viewModel
              ..phase = ServerAccessPhase.failed
              ..blocker = null
              ..error = _friendlyError(server, error);
          });
          onChanged?.call();
          _maybeScheduleReconnect();
        }
    }
  }

  Future<void> _probeAfterResume() async {
    if (_resumeProbeRunning || _appPaused || !_wantsConnection) return;
    _resumeProbeRunning = true;
    try {
      await sessions.refresh();
    } catch (error) {
      await _markConnectionLostAndReconnect('session refresh failed: $error');
    } finally {
      _resumeProbeRunning = false;
    }
  }

  Future<void> _markConnectionLostAndReconnect(String message) async {
    if (_appPaused || !_wantsConnection) return;
    await transport.close();
    observationTransaction(() {
      viewModel
        ..phase = ServerAccessPhase.failed
        ..error = message
        ..blocker = null;
    });
    onChanged?.call();
    _cancelReconnect();
    _maybeScheduleReconnect(immediate: true);
  }

  void _maybeScheduleReconnect({bool immediate = false}) {
    if (_appPaused || !_wantsConnection || _reconnectTimer != null) return;
    final server = serverProvider();
    if (server == null) return;
    final blocker = resolver.currentBlocker(server);
    if (blocker != null) {
      _setBlocked(blocker);
      return;
    }
    final attempt = _reconnectAttempts;
    final delay = immediate ? Duration.zero : _reconnectDelay(attempt);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_attemptReconnect());
    });
  }

  Future<void> _attemptReconnect() async {
    if (_appPaused || !_wantsConnection || _reconnecting) return;
    _reconnecting = true;
    _reconnectAttempts++;
    try {
      await _connect(force: true, reconnect: true);
    } finally {
      _reconnecting = false;
    }
    if (_wantsConnection && !isLive) _maybeScheduleReconnect();
  }

  Duration _reconnectDelay(int attempt) {
    final base =
        _reconnectBaseDelay.inMilliseconds * (1 << attempt.clamp(0, 6));
    final capped = base.clamp(0, _reconnectMaxDelay.inMilliseconds);
    return Duration(milliseconds: capped);
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _setIdle() {
    observationTransaction(() {
      viewModel
        ..phase = ServerAccessPhase.idle
        ..blocker = null
        ..error = null;
    });
    onChanged?.call();
  }

  void _setBlocked(ConnectionBlocker blocker) {
    observationTransaction(() {
      viewModel
        ..phase = ServerAccessPhase.blocked
        ..blocker = blocker
        ..error = null
        ..transport = blocker.transport;
    });
    onChanged?.call();
  }

  ConnectionBlocker _fallbackBlocker() => ConnectionBlocker.transport(
    'transport unavailable',
    kind: serverProvider()?.kind ?? ServerKind.direct,
  );

  String _friendlyError(MotifServer server, Object error) {
    final message = '$error';
    return switch (server.kind) {
      ServerKind.tailscale =>
        "Can't reach ${server.endpoint} over Tailscale. $message",
      ServerKind.ssh =>
        "Can't reach ${server.endpoint} through the SSH tunnel. $message",
      ServerKind.wsl => "Can't reach ${server.endpoint} through WSL. $message",
      _ => "Can't reach ${server.endpoint}. $message",
    };
  }
}
