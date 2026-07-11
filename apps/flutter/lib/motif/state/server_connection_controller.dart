import 'dart:async';

import 'package:flutter/foundation.dart';

import '../log/log.dart';
import '../models/settings.dart';
import '../platform/services.dart';
import 'connection_state.dart';
import 'motif_client.dart';
import 'server_connection_runtime.dart';
import 'transport_resolver.dart';

class ServerConnectionController implements ServerConnectionRuntimeHost {
  static const Duration _reconnectBaseDelay = Duration(milliseconds: 500);
  static const Duration _reconnectMaxDelay = Duration(seconds: 30);

  final String serverId;
  final MotifClient client;
  final MotifServer? Function() serverProvider;
  final TransportResolver resolver;
  final VoidCallback onChanged;
  final ServerConnectionRuntime runtime;

  ServerConnectionController({
    required this.serverId,
    required this.client,
    required this.serverProvider,
    required this.resolver,
    required this.onChanged,
    ServerConnectionRuntime? runtime,
  }) : runtime = runtime ?? const MobileServerConnectionRuntime();

  ServerConnectionState _state = const ServerIdle();
  ServerConnectionState get state => _state;

  MotifConnState? _lastClientState;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _reconnecting = false;
  bool _wantsConnection = false;
  bool _appPaused = false;
  bool _resumeProbeRunning = false;

  bool get wantsConnection => _wantsConnection;

  Future<void> connect({bool force = false}) async {
    _wantsConnection = true;
    _cancelReconnect();
    await _connect(force: force, reconnect: false);
  }

  Future<void> disconnect() async {
    _wantsConnection = false;
    _reconnectAttempts = 0;
    _cancelReconnect();
    await client.disconnect();
    // Tear down the rendezvous loopback forwarder (no-op for other transports)
    // so we don't keep parked relay connections open after an explicit
    // disconnect. Reconnects re-resolve and start a fresh one.
    await resolver.stopForwarder(serverId);
    // Drop learned LAN-direct candidates so the next session starts on the
    // relay and re-learns them (the network may have changed meanwhile).
    resolver.forgetRzvDirect(serverId);
    _setState(const ServerIdle());
  }

  /// Project a real client connection transition into the server-level state.
  ///
  /// [MotifClient] also notifies for session/view data changes. Those updates
  /// must not be mistaken for connection transitions, otherwise every event is
  /// amplified into an extra app-wide notification.
  bool handleClientStateChanged({bool notify = true}) {
    final previous = _lastClientState;
    final next = client.state;
    if (identical(previous, next)) return false;
    _lastClientState = next;

    switch (next) {
      case ConnDisconnected():
        if (!_wantsConnection) _setState(const ServerIdle(), notify: notify);
      case ConnConnecting():
        _setState(
          _reconnecting
              ? ServerReconnecting(
                  session: client.intendedSession,
                  attempt: _reconnectAttempts,
                )
              : const ServerConnecting(),
          notify: notify,
        );
      case ConnConnected():
        _markConnected();
        final notice = client.connectionNotice;
        _setState(
          notice == null ? const ServerConnected() : ServerFailed(notice),
          notify: notify,
        );
      case ConnAttached(:final session):
        _markConnected();
        _setState(ServerAttached(session), notify: notify);
      case ConnSuspended(:final session, :final message):
        if (_state is! ServerSuspended) {
          final server = serverProvider();
          _setState(
            ServerSuspended(
              session: session,
              blocker: ConnectionBlocker.transport(
                message,
                kind: server?.kind ?? ServerKind.direct,
              ),
            ),
            notify: notify,
          );
        }
      case ConnFailed(:final message):
        final session = client.intendedSession;
        _setState(ServerFailed(message, session: session), notify: notify);
        if (_wantsConnection && previous is! ConnFailed) {
          _maybeScheduleReconnect();
        }
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
    if (client.isLive || client.hasTerminalSnapshot) {
      _wantsConnection = true;
      _setState(
        ServerSuspended(session: client.intendedSession, blocker: blocker),
      );
      unawaited(_suspendClient(blocker));
    } else {
      _setState(ServerBlocked(blocker));
    }
  }

  void handleAppPaused() => runtime.handleAppPaused(this);

  void handleAppResumed() => runtime.handleAppResumed(this);

  @override
  void handleMobileAppPaused() {
    _appPaused = true;
    client.setForeground(false);
    _cancelReconnect();
    Log.i(
      'app paused server=$serverId clientState=${client.state.runtimeType} '
      'controllerState=${_state.runtimeType} wants=$_wantsConnection '
      'live=${client.isLive}',
      name: 'motif.resume',
    );
  }

  @override
  void handleMobileAppResumed() {
    _appPaused = false;
    client.setForeground(true);
    Log.i(
      'app resumed server=$serverId clientState=${client.state.runtimeType} '
      'controllerState=${_state.runtimeType} wants=$_wantsConnection '
      'live=${client.isLive} session=${client.intendedSession}',
      name: 'motif.resume',
    );
    if (!_wantsConnection) return;
    final server = serverProvider();
    if (server == null) return;
    final blocker = resolver.currentBlocker(server);
    if (blocker != null) {
      _setState(
        client.hasTerminalSnapshot
            ? ServerSuspended(session: client.intendedSession, blocker: blocker)
            : ServerBlocked(blocker),
      );
      return;
    }
    if (_state is ServerSuspended ||
        _state is ServerBlocked ||
        _state is ServerFailed ||
        client.state is ConnFailed ||
        client.state is ConnSuspended) {
      _maybeScheduleReconnect(immediate: true);
      return;
    }
    if (client.state is ConnAttached) {
      _maybeScheduleReconnect(immediate: true);
      return;
    }
    if (client.isLive) {
      unawaited(_probeLiveConnectionAfterResume());
    }
  }

  @override
  void reclaimForeground() {
    client.setForeground(true);
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
      'reconnect=$reconnect session=${client.intendedSession}',
      name: 'motif.resume',
    );

    final session = client.intendedSession;
    _setState(
      reconnect
          ? ServerReconnecting(session: session, attempt: _reconnectAttempts)
          : const ServerConnecting(),
    );

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
        if (client.isLive || client.hasTerminalSnapshot) {
          _setState(ServerSuspended(session: session, blocker: blocker));
          unawaited(_suspendClient(blocker));
        } else {
          _setState(ServerBlocked(blocker));
        }
        return;
      case TransportReady(:final target, :final proxy, :final certPin):
        stage = Stopwatch()..start();
        try {
          await client.connect(
            target,
            force: force,
            proxy: proxy,
            certPin: certPin,
          );
          Log.i(
            'connect stage server=$serverId stage=client-connect '
            'took=${stage.elapsedMilliseconds}ms total=${total.elapsedMilliseconds}ms '
            'clientState=${client.state.runtimeType}',
            name: 'motif.resume',
          );
          _maybeUpgradeToDirect(server);
        } catch (e) {
          Log.w(
            'connect failed server=$serverId stage=client-connect '
            'took=${stage.elapsedMilliseconds}ms total=${total.elapsedMilliseconds}ms',
            name: 'motif.resume',
            error: e,
          );
          _setState(ServerFailed('$e', session: session));
          _maybeScheduleReconnect();
        }
    }
  }

  /// After a successful rendezvous connect over the relay, learn the LAN-direct
  /// candidates the server advertised on `/ping`. When they first become
  /// available, kick an immediate reconnect so [resolve] can probe them and
  /// upgrade onto a direct connection (the relay forwarder is torn down there).
  void _maybeUpgradeToDirect(MotifServer server) {
    if (kIsWeb || server.kind != ServerKind.rendezvous) return;
    if (resolver.learnRzvDirect(server, client.lastPing)) {
      _maybeScheduleReconnect(immediate: true);
    }
  }

  void _handleTailscaleRunning() {
    final wasBlocked = _state is ServerBlocked;
    if (!_wantsConnection) {
      if (wasBlocked) _setState(const ServerIdle());
      return;
    }
    if (_state is ServerBlocked ||
        _state is ServerSuspended ||
        _state is ServerFailed ||
        client.state is ConnSuspended ||
        client.state is ConnFailed) {
      _maybeScheduleReconnect(immediate: true);
    }
  }

  void _markConnected() {
    _reconnectAttempts = 0;
    _reconnecting = false;
    _cancelReconnect();
  }

  void _maybeScheduleReconnect({bool immediate = false}) {
    if (_appPaused || !_wantsConnection) return;
    final server = serverProvider();
    if (server == null) return;
    final blocker = resolver.currentBlocker(server);
    if (blocker != null) {
      _setState(
        client.hasTerminalSnapshot
            ? ServerSuspended(session: client.intendedSession, blocker: blocker)
            : ServerBlocked(blocker),
      );
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
    final sw = Stopwatch()..start();
    _reconnecting = true;
    _reconnectAttempts++;
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
        'took=${sw.elapsedMilliseconds}ms state=${client.state.runtimeType}',
        name: 'motif.resume',
      );
    }
    if (_wantsConnection && client.state is ConnFailed) {
      _maybeScheduleReconnect();
    }
  }

  Future<void> _probeLiveConnectionAfterResume() async {
    if (_resumeProbeRunning || _appPaused || !_wantsConnection) return;
    _resumeProbeRunning = true;
    try {
      await client.refreshSessions();
    } catch (e, st) {
      Log.w(
        'resume probe failed; reconnecting server=$serverId',
        name: 'motif.reconnect',
        error: e,
        stackTrace: st,
      );
      await _markConnectionLostAndReconnect('session refresh failed: $e');
    } finally {
      _resumeProbeRunning = false;
    }
  }

  Future<void> _markConnectionLostAndReconnect(String message) async {
    if (_appPaused || !_wantsConnection) return;
    Log.i(
      'mark connection lost server=$serverId message=$message',
      name: 'motif.reconnect',
    );
    await client.markConnectionLost(message);
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

  Future<void> _suspendClient(ConnectionBlocker blocker) async {
    await client.suspendTransport(blocker.message);
    if (client.isLive) {
      await client.disconnect();
    }
  }

  void _setState(ServerConnectionState state, {bool notify = true}) {
    _state = state;
    if (notify) onChanged();
  }
}
