import 'dart:async';

import 'package:flutter/foundation.dart';

import '../log/log.dart';
import '../models/settings.dart';
import '../platform/services.dart';
import 'connection_state.dart';
import 'motif_client.dart';
import 'transport_resolver.dart';

class ServerConnectionController {
  static const Duration _reconnectBaseDelay = Duration(milliseconds: 500);
  static const Duration _reconnectMaxDelay = Duration(seconds: 30);

  final String serverId;
  final MotifClient client;
  final MotifServer? Function() serverProvider;
  final TransportResolver resolver;
  final VoidCallback onChanged;

  ServerConnectionController({
    required this.serverId,
    required this.client,
    required this.serverProvider,
    required this.resolver,
    required this.onChanged,
  });

  ServerConnectionState _state = const ServerIdle();
  ServerConnectionState get state => _state;

  MotifConnState? _lastClientState;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _reconnecting = false;
  bool _wantsConnection = false;
  bool _appPaused = false;

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
    _setState(const ServerIdle());
  }

  void handleClientStateChanged() {
    final previous = _lastClientState;
    final next = client.state;
    _lastClientState = next;

    switch (next) {
      case ConnDisconnected():
        if (!_wantsConnection) _setState(const ServerIdle());
      case ConnConnecting():
        _setState(
          _reconnecting
              ? ServerReconnecting(
                  session: client.intendedSession,
                  attempt: _reconnectAttempts,
                )
              : const ServerConnecting(),
        );
      case ConnConnected():
        _markConnected();
        final notice = client.connectionNotice;
        _setState(
          notice == null ? const ServerConnected() : ServerFailed(notice),
        );
      case ConnAttached(:final session):
        _markConnected();
        _setState(ServerAttached(session));
      case ConnSuspended(:final session, :final message):
        if (_state is! ServerSuspended) {
          _setState(
            ServerSuspended(
              session: session,
              blocker: ConnectionBlocker.transport(message),
            ),
          );
        }
      case ConnFailed(:final message):
        final session = client.intendedSession;
        _setState(ServerFailed(message, session: session));
        if (_wantsConnection && previous is! ConnFailed) {
          _maybeScheduleReconnect();
        }
    }
  }

  void handleTailscaleState(TailscaleState tailscaleState) {
    final server = serverProvider();
    if (server == null || server.kind != ServerKind.tailscale) return;

    if (tailscaleState.status == TailscaleStatus.running) {
      _handleTailscaleRunning();
      return;
    }

    final blocker = ConnectionBlocker.tailscale(tailscaleState);
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
      _setState(
        client.hasTerminalSnapshot
            ? ServerSuspended(session: client.intendedSession, blocker: blocker)
            : ServerBlocked(blocker),
      );
      return;
    }
    if (_state is ServerSuspended ||
        _state is ServerBlocked ||
        client.state is ConnFailed ||
        client.state is ConnSuspended) {
      _maybeScheduleReconnect(immediate: true);
    }
  }

  void dispose() {
    _cancelReconnect();
  }

  Future<void> _connect({required bool force, required bool reconnect}) async {
    final server = serverProvider();
    if (server == null) return;

    final session = client.intendedSession;
    _setState(
      reconnect
          ? ServerReconnecting(session: session, attempt: _reconnectAttempts)
          : const ServerConnecting(),
    );

    final resolution = await resolver.resolve(server);
    switch (resolution) {
      case TransportBlocked(:final blocker):
        if (client.isLive || client.hasTerminalSnapshot) {
          _setState(ServerSuspended(session: session, blocker: blocker));
          unawaited(_suspendClient(blocker));
        } else {
          _setState(ServerBlocked(blocker));
        }
        return;
      case TransportFailed(:final message):
        _setState(ServerFailed(message, session: session));
        _maybeScheduleReconnect();
        return;
      case TransportReady(:final target, :final proxy):
        try {
          await client.connect(target, force: force, proxy: proxy);
        } catch (e) {
          _setState(ServerFailed('$e', session: session));
          _maybeScheduleReconnect();
        }
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
    _reconnecting = true;
    _reconnectAttempts++;
    try {
      await _connect(force: true, reconnect: true);
    } finally {
      _reconnecting = false;
    }
    if (_wantsConnection && client.state is ConnFailed) {
      _maybeScheduleReconnect();
    }
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

  void _setState(ServerConnectionState state) {
    _state = state;
    onChanged();
  }
}
