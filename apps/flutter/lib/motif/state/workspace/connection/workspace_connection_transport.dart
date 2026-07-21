part of 'workspace_connection_controller.dart';

/// Transport lifecycle and reconnect policy for [WorkspaceConnectionController].
extension _WorkspaceConnectionControllerConnection
    on WorkspaceConnectionController {
  Future<bool> _probeTransportImpl() async {
    final rpc = _rpc;
    if (rpc == null || !supportsResumeProbe) return false;
    final sw = Stopwatch()..start();
    try {
      final result = await rpc.probeSessionStreams();
      if (!identical(_rpc, rpc) || !connection.transportAvailable) return false;
      if (!result.eventsAlive) {
        Log.w(
          'resume probe failed channel=events took=${sw.elapsedMilliseconds}ms',
          name: 'motif.resume',
        );
        return false;
      }
      if (result.failedPtyIds.isNotEmpty) {
        Log.w(
          'resume probe repairing ptys=${result.failedPtyIds.join(",")} '
          'took=${sw.elapsedMilliseconds}ms',
          name: 'motif.resume',
        );
        await rpc.reopenPtyStreams(result.failedPtyIds);
      }
      final healthy = identical(_rpc, rpc) && connection.transportAvailable;
      Log.i(
        'resume probe healthy=$healthy repaired=${result.failedPtyIds.length} '
        'took=${sw.elapsedMilliseconds}ms',
        name: 'motif.resume',
      );
      return healthy;
    } catch (e, st) {
      Log.w(
        'resume probe failed',
        name: 'motif.resume',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  Future<void> _connectImpl(
    MotifServer server, {
    required bool force,
    required ProxySettings proxy,
    required Uint8List? certPin,
  }) async {
    if (!force && (_state is ConnConnected || _state is ConnAttached)) return;
    _attachmentRuntime.reset();
    final total = Stopwatch()..start();
    var stage = Stopwatch()..start();

    if (force && _rpc != null) {
      _carriedPtyCursors = _rpc!.ptyCursors();
      await _teardownRpc();
      Log.i(
        'reconnect stage=teardown took=${stage.elapsedMilliseconds}ms '
        'session=$session cursors=${_carriedPtyCursors.length}',
        name: 'motif.resume',
      );
    }

    _setState(const ConnConnecting());

    final rpc = RpcClient()
      ..connect(
        host: server.host,
        port: server.port,
        scheme: server.scheme,
        token: server.token,
        proxy: proxy,
        certPin: certPin,
      );

    try {
      stage = Stopwatch()..start();
      final ping = await _pingWithRetry(rpc, server);
      Log.i(
        'reconnect stage=ping took=${stage.elapsedMilliseconds}ms '
        'session=$session',
        name: 'motif.resume',
      );
      if (!ping.isMotifServer) {
        await rpc.close();
        _setState(ConnFailed('Not a motif server at ${server.endpoint}'));
        return;
      }
      lastPing = ping;
    } catch (e) {
      await rpc.close();
      _setState(ConnFailed(_friendlyError(server, e)));
      return;
    }

    _setRpc(rpc);
    if (_carriedPtyCursors.isNotEmpty) {
      rpc.seedPtyCursors(_carriedPtyCursors);
      _carriedPtyCursors = {};
    }

    _eventSub = rpc.events.listen(events.handle, onDone: _handleConnectionLost);

    try {
      stage = Stopwatch()..start();
      await attach();
      Log.i(
        'reconnect stage=attach took=${stage.elapsedMilliseconds}ms '
        'total=${total.elapsedMilliseconds}ms session=$session',
        name: 'motif.resume',
      );
      final pending = pendingLocalViewId;
      if (pending != null) {
        if (pending != _viewState.activeViewId &&
            _viewState.items.any((view) => view.id == pending)) {
          await viewsController.activate(pending);
        }
        pendingLocalViewId = null;
      }
    } catch (error) {
      if (_isSessionNotFound(error)) {
        _attachmentRuntime.reset();
        resumeSequence = null;
        _carriedPtyCursors = {};
        pendingLocalViewId = null;
        lastSeq = 0;
        presence.sessionTheme = null;
        _clearSessionState();
        _setState(const ConnConnected());
      } else {
        if (_rpc != null) _carriedPtyCursors = _rpc!.ptyCursors();
        await _teardownRpc();
        _setState(ConnFailed('reattach failed: $error'));
      }
    }
  }

  bool _isSessionNotFound(Object error) =>
      error is RpcException && error.code == _kSessionNotFound;

  bool _isNotAttached(Object error) =>
      error is RpcException && error.code == _kNotAttached;

  Future<PingInfo> _pingWithRetry(RpcClient rpc, MotifServer server) async {
    final sw = Stopwatch()..start();
    try {
      return await rpc.ping();
    } catch (e) {
      final delay = server.kind == ServerKind.tailscale
          ? const Duration(milliseconds: 900)
          : const Duration(milliseconds: 350);
      Log.w(
        'ping first attempt failed after=${sw.elapsedMilliseconds}ms '
        'kind=${server.kind.name} retryDelay=${delay.inMilliseconds}ms',
        name: 'motif.resume',
        error: e,
      );
      await Future<void>.delayed(delay);
      final retry = Stopwatch()..start();
      final result = await rpc.ping();
      Log.i(
        'ping retry succeeded took=${retry.elapsedMilliseconds}ms '
        'total=${sw.elapsedMilliseconds}ms',
        name: 'motif.resume',
      );
      return result;
    }
  }

  Future<void> _teardownRpc() async {
    await remotePorts.stopAll();
    await _eventSub?.cancel();
    _eventSub = null;
    await _rpc?.close();
    _setRpc(null);
  }

  Future<void> _disconnectImpl() async {
    _attachmentRuntime.reset();
    await _teardownRpc();
    _clearSessionState();
    resumeSequence = null;
    _carriedPtyCursors = {};
    pendingLocalViewId = null;
    lastSeq = 0;
    _setState(const ConnDisconnected());
  }

  Future<void> _suspendTransportImpl(String reason) async {
    _attachmentRuntime.reset();
    final s = _state;
    if (s is ConnAttached && lastSeq > 0) {
      resumeSequence = lastSeq;
    }
    if (_rpc != null) _carriedPtyCursors = _rpc!.ptyCursors();
    if (viewsController.hasPendingActivation) {
      pendingLocalViewId = _viewState.activeViewId;
      viewsController.completePendingActivation();
    }
    await _teardownRpc();
    _setState(ConnSuspended(reason, session: session));
  }

  void _setForegroundImpl(bool foreground) {
    if (isForeground == foreground) return;
    isForeground = foreground;
    if (foreground) _reclaimPrimary();
  }

  void _clearSessionState() {
    terminal.clear();
    viewsController.clear();
    presence.clients.clear();
  }

  Future<void> _handleConnectionLost([
    String message = 'connection lost',
  ]) async {
    _attachmentRuntime.reset();
    final s = _state;
    if (s is ConnAttached && lastSeq > 0) {
      resumeSequence = lastSeq;
    }
    if (_rpc != null) _carriedPtyCursors = _rpc!.ptyCursors();
    await _eventSub?.cancel();
    _eventSub = null;
    await _rpc?.close();
    _setRpc(null);
    await remotePorts.stopAll();
    if (viewsController.hasPendingActivation) {
      pendingLocalViewId = _viewState.activeViewId;
      viewsController.completePendingActivation();
    }
    // Keep terminal/view snapshots so the terminal stays on screen offline.
    _setState(ConnFailed(message));
  }

  void _setState(WorkspaceConnectionStatus state) {
    _state = state;
  }

  String _friendlyError(MotifServer server, Object error) {
    if (error is RpcException) {
      if (error.code != null) {
        return 'Server error ${error.code}: ${error.message}';
      }
      return error.message;
    }
    final message = error.toString();
    if (server.kind == ServerKind.tailscale) {
      return "Can't reach ${server.endpoint} over Tailscale. Check MagicDNS "
          'and that the peer is online.\n$message';
    }
    if (server.kind == ServerKind.ssh) {
      return "Can't reach ${server.endpoint} through the SSH tunnel. Check the "
          'SSH login, remote motifd host/port, and that motifd is running.\n'
          '$message';
    }
    if (server.kind == ServerKind.wsl) {
      return "Can't reach 127.0.0.1:${server.port} through WSL. Check that the "
          'distribution is installed and WSL localhost forwarding is enabled.\n'
          '$message';
    }
    return "Can't reach ${server.endpoint}. Check the host/port and that "
        'motifd is running.\n$message';
  }
}
