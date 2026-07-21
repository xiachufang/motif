import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../log/log.dart';
import '../../models/settings.dart';
import '../connection/connection_state.dart';
import '../platform/tailscale_view_model.dart';
import 'workspace_retention_policy.dart';
import '../server/transport_resolver.dart';
import 'connection/workspace_connection_controller.dart';
import 'connection/workspace_connection_view_model.dart';

/// Reconnect policy for one fixed workspace connection.
///
/// This controller owns timers and transport resolution only. Its complete
/// observable projection lives in [WorkspaceConnectionController.connection];
/// there is deliberately no parallel ServerAccessViewModel for a workspace.
final class WorkspaceLifecycleController implements WorkspaceRetentionHost {
  static const Duration _reconnectBaseDelay = Duration(milliseconds: 500);
  static const Duration _reconnectMaxDelay = Duration(seconds: 30);

  WorkspaceLifecycleController({
    required this.serverId,
    required this.connection,
    required this.serverProvider,
    required this.resolver,
    WorkspaceRetentionPolicy? retentionPolicy,
  }) : retentionPolicy =
           retentionPolicy ?? const MobileWorkspaceRetentionPolicy();

  final String serverId;
  final WorkspaceConnectionController connection;
  final MotifServer? Function() serverProvider;
  final TransportResolver resolver;
  final WorkspaceRetentionPolicy retentionPolicy;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _reconnecting = false;
  bool _wantsConnection = false;
  bool _appPaused = false;
  ({
    WorkspaceConnectionPhase phase,
    String? message,
    String? attachedSession,
    bool transportAvailable,
  })?
  _lastProjection;

  bool get wantsConnection => _wantsConnection;

  Future<void> connect({bool force = false}) async {
    _wantsConnection = true;
    connection.connection.desiredConnected = true;
    _cancelReconnect();
    await _connect(force: force, reconnect: false);
  }

  Future<void> disconnect() async {
    _wantsConnection = false;
    _reconnectAttempts = 0;
    _cancelReconnect();
    await connection.disconnect();
    await resolver.stopForwarder(serverId);
    resolver.forgetRzvDirect(serverId);
    observationTransaction(() {
      connection.connection
        ..desiredConnected = false
        ..reconnectAttempt = 0
        ..blocker = null;
    });
  }

  /// Reconciles transport-owned status changes with reconnect metadata.
  bool handleConnectionStateChanged() {
    final viewModel = connection.connection;
    final projection = (
      phase: viewModel.phase,
      message: viewModel.message,
      attachedSession: viewModel.attachedSession,
      transportAvailable: viewModel.transportAvailable,
    );
    if (_lastProjection == projection) return false;
    _lastProjection = projection;

    switch (connection.state) {
      case ConnDisconnected():
        if (!_wantsConnection) {
          observationTransaction(() {
            viewModel
              ..desiredConnected = false
              ..reconnectAttempt = 0
              ..blocker = null;
          });
        }
      case ConnConnecting():
        observationTransaction(() {
          viewModel
            ..desiredConnected = true
            ..phase = _reconnecting
                ? WorkspaceConnectionPhase.reconnecting
                : WorkspaceConnectionPhase.connecting
            ..reconnectAttempt = _reconnectAttempts
            ..blocker = null;
        });
      case ConnConnected() || ConnAttached():
        _markConnected();
        observationTransaction(() {
          viewModel
            ..desiredConnected = true
            ..reconnectAttempt = 0
            ..blocker = null;
        });
      case ConnSuspended(:final message):
        final server = serverProvider();
        viewModel.blocker ??= ConnectionBlocker.transport(
          message,
          kind: server?.kind ?? ServerKind.direct,
        );
      case ConnFailed():
        viewModel.blocker = null;
        if (_wantsConnection) _maybeScheduleReconnect();
    }
    return true;
  }

  void handleTailscaleState(TailscaleState _) {
    final server = serverProvider();
    if (server == null || server.kind != ServerKind.tailscale) return;

    final blocker = resolver.currentBlocker(server);
    if (blocker == null) {
      _handleTailscaleRunning();
      return;
    }

    _cancelReconnect();
    if (connection.isLive || connection.hasTerminalSnapshot) {
      _wantsConnection = true;
      _projectBlocked(blocker);
      unawaited(_suspendConnection(blocker));
    } else {
      _projectBlocked(blocker);
    }
  }

  void handleAppPaused() => retentionPolicy.handleAppPaused(this);

  void handleAppResumed() => retentionPolicy.handleAppResumed(this);

  @override
  void handleMobileAppPaused() {
    _appPaused = true;
    connection.setForeground(false);
    _cancelReconnect();
    Log.i(
      'app paused server=$serverId workspaceState=${connection.state.runtimeType} '
      'wants=$_wantsConnection live=${connection.isLive}',
      name: 'motif.resume',
    );
  }

  @override
  void handleMobileAppResumed() {
    _appPaused = false;
    connection.setForeground(true);
    Log.i(
      'app resumed server=$serverId workspaceState=${connection.state.runtimeType} '
      'wants=$_wantsConnection live=${connection.isLive} '
      'session=${connection.session}',
      name: 'motif.resume',
    );
    if (!_wantsConnection) return;
    final server = serverProvider();
    if (server == null) return;
    final blocker = resolver.currentBlocker(server);
    if (blocker != null) {
      _projectBlocked(blocker);
      return;
    }
    _maybeScheduleReconnect(immediate: true);
  }

  @override
  void reclaimForeground() {
    connection.setForeground(true);
  }

  void handleTransportFailure(Object error, [StackTrace? stackTrace]) {
    if (!_wantsConnection || _appPaused) return;
    Log.w(
      'workspace transport failed; reconnecting server=$serverId',
      name: 'motif.reconnect',
      error: error,
      stackTrace: stackTrace,
    );
    unawaited(
      _markConnectionLostAndReconnect('workspace transport failed: $error'),
    );
  }

  void dispose() {
    _cancelReconnect();
    unawaited(resolver.stopForwarder(serverId));
    resolver.forgetRzvDirect(serverId);
  }

  Future<void> _connect({required bool force, required bool reconnect}) async {
    final server = serverProvider();
    if (server == null) return;
    final total = Stopwatch()..start();
    var stage = Stopwatch()..start();
    Log.i(
      'connect begin server=$serverId kind=${server.kind.name} force=$force '
      'reconnect=$reconnect session=${connection.session}',
      name: 'motif.resume',
    );

    _projectResolving(reconnect: reconnect);
    if (force || reconnect) {
      await resolver.stopForwarder(server.id);
      Log.i(
        'connect stage server=$serverId stage=stop-forwarder '
        'took=${stage.elapsedMilliseconds}ms',
        name: 'motif.resume',
      );
      stage = Stopwatch()..start();
    }

    final resolution = await resolver.resolve(server);
    Log.i(
      'connect stage server=$serverId stage=resolve '
      'took=${stage.elapsedMilliseconds}ms result=${resolution.runtimeType}',
      name: 'motif.resume',
    );
    switch (resolution) {
      case TransportBlocked(:final blocker):
        _projectBlocked(blocker);
        if (connection.isLive || connection.hasTerminalSnapshot) {
          unawaited(_suspendConnection(blocker));
        }
        return;
      case TransportReady(:final target, :final proxy, :final certPin):
        stage = Stopwatch()..start();
        try {
          await connection.connect(
            target,
            force: force,
            proxy: proxy,
            certPin: certPin,
          );
          handleConnectionStateChanged();
          Log.i(
            'connect stage server=$serverId stage=workspace-connect '
            'took=${stage.elapsedMilliseconds}ms '
            'total=${total.elapsedMilliseconds}ms '
            'workspaceState=${connection.state.runtimeType}',
            name: 'motif.resume',
          );
          _maybeUpgradeToDirect(server);
        } catch (error) {
          Log.w(
            'connect failed server=$serverId stage=workspace-connect '
            'took=${stage.elapsedMilliseconds}ms '
            'total=${total.elapsedMilliseconds}ms',
            name: 'motif.resume',
            error: error,
          );
          connection.connection.applyStatus(ConnFailed('$error'), live: false);
          _maybeScheduleReconnect();
        }
    }
  }

  void _maybeUpgradeToDirect(MotifServer server) {
    if (kIsWeb || server.kind != ServerKind.rendezvous) return;
    if (resolver.learnRzvDirect(server, connection.lastPing)) {
      _maybeScheduleReconnect(immediate: true);
    }
  }

  void _handleTailscaleRunning() {
    final phase = connection.connection.phase;
    if (!_wantsConnection) {
      if (phase == WorkspaceConnectionPhase.suspended) {
        connection.connection.applyStatus(
          const ConnDisconnected(),
          live: false,
        );
      }
      return;
    }
    if (phase == WorkspaceConnectionPhase.suspended ||
        phase == WorkspaceConnectionPhase.failed) {
      _maybeScheduleReconnect(immediate: true);
    }
  }

  void _markConnected() {
    _reconnectAttempts = 0;
    _reconnecting = false;
    _cancelReconnect();
  }

  void _projectResolving({required bool reconnect}) {
    observationTransaction(() {
      connection.connection
        ..desiredConnected = true
        ..phase = reconnect
            ? WorkspaceConnectionPhase.reconnecting
            : WorkspaceConnectionPhase.connecting
        ..reconnectAttempt = reconnect ? _reconnectAttempts : 0
        ..message = null
        ..blocker = null;
    });
  }

  void _projectBlocked(ConnectionBlocker blocker) {
    observationTransaction(() {
      connection.connection
        ..desiredConnected = true
        ..phase = WorkspaceConnectionPhase.suspended
        ..transportAvailable = false
        ..message = blocker.message
        ..blocker = blocker;
    });
  }

  void _maybeScheduleReconnect({bool immediate = false}) {
    if (_appPaused || !_wantsConnection) return;
    final server = serverProvider();
    if (server == null) return;
    final blocker = resolver.currentBlocker(server);
    if (blocker != null) {
      _projectBlocked(blocker);
      return;
    }
    if (_reconnectTimer != null || _reconnecting) return;

    final attempt = _reconnectAttempts;
    final delay = immediate ? Duration.zero : _reconnectDelay(attempt);
    Log.i(
      'schedule reconnect server=$serverId attempt=$attempt '
      'delay=${delay.inMilliseconds}ms',
      name: 'motif.reconnect',
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_attemptReconnect());
    });
  }

  Future<void> _attemptReconnect() async {
    if (_appPaused || !_wantsConnection || _reconnecting) return;
    final stopwatch = Stopwatch()..start();
    _reconnecting = true;
    _reconnectAttempts++;
    connection.connection.reconnectAttempt = _reconnectAttempts;
    Log.i(
      'resume reconnect begin server=$serverId attempt=$_reconnectAttempts',
      name: 'motif.resume',
    );
    try {
      await _connect(force: true, reconnect: true);
    } finally {
      _reconnecting = false;
      Log.i(
        'resume reconnect end server=$serverId attempt=$_reconnectAttempts '
        'took=${stopwatch.elapsedMilliseconds}ms '
        'state=${connection.state.runtimeType}',
        name: 'motif.resume',
      );
    }
    if (_wantsConnection && connection.state is ConnFailed) {
      _maybeScheduleReconnect();
    }
  }

  Future<void> _markConnectionLostAndReconnect(String message) async {
    if (_appPaused || !_wantsConnection) return;
    Log.i(
      'mark connection lost server=$serverId message=$message',
      name: 'motif.reconnect',
    );
    await connection.markConnectionLost(message);
    _cancelReconnect();
    _maybeScheduleReconnect(immediate: true);
  }

  Duration _reconnectDelay(int attempt) {
    final base =
        _reconnectBaseDelay.inMilliseconds * (1 << attempt.clamp(0, 6));
    final capped = base.clamp(0, _reconnectMaxDelay.inMilliseconds);
    final jitter =
        (capped * 0.2 * (DateTime.now().microsecondsSinceEpoch % 1000) / 1000)
            .round();
    return Duration(milliseconds: capped + jitter);
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  Future<void> _suspendConnection(ConnectionBlocker blocker) =>
      connection.suspendTransport(blocker.message);
}
