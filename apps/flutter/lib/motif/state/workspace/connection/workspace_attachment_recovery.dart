part of 'workspace_connection_controller.dart';

/// Attachment recovery shared by focused feature transports.
extension _WorkspaceConnectionControllerRecovery
    on WorkspaceConnectionController {
  Future<RpcClient?> _waitForAttachedRpc() async {
    if (_attachmentRuntime.isBusy) {
      try {
        await _attachmentRuntime.waitForSettled();
      } catch (_) {
        return null;
      }
    }

    final rpc = _rpc;
    final state = _state;
    if (rpc == null || rpc.sessionId == null || state is! ConnAttached) {
      return null;
    }
    if (state.session != session) return null;
    return rpc;
  }

  /// Run a terminal command that needs a response body. Unlike high-frequency
  /// stream operations, a command failure must surface to its caller. Socket
  /// failures also invalidate the workspace transport immediately so the
  /// owning lifecycle machine can rebuild the route instead of waiting for a
  /// WebSocket close callback.
  Future<Map<String, Object?>> _runAttachedTerminalCall(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final rpc = await _waitForAttachedRpc();
    if (rpc == null) throw const RpcException('not connected');
    try {
      return await rpc.call(method, params);
    } catch (error, stackTrace) {
      if (isTransportConnectionFailure(error) && identical(_rpc, rpc)) {
        Log.w(
          'terminal RPC lost transport method=$method',
          name: 'motif.session',
          error: error,
          stackTrace: stackTrace,
        );
        await _handleConnectionLost('connection lost during $method');
      }
      rethrow;
    }
  }

  Future<void> _runAttachedTerminalRpc(
    Future<void> Function(RpcClient rpc) operation,
  ) async {
    final rpc = await _waitForAttachedRpc();
    if (rpc == null) return;
    final attemptedSessionId = rpc.sessionId!;
    try {
      await operation(rpc);
      return;
    } catch (error, stackTrace) {
      if (!_isNotAttached(error)) rethrow;
      Log.w(
        'session attachment expired; reattaching terminal transport',
        name: 'motif.session',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (rpc.sessionId == attemptedSessionId) {
      await _attachmentRuntime.recover(attemptedSessionId);
    }
    final recovered = await _waitForAttachedRpc();
    if (recovered == null) return;
    await operation(recovered);
  }

  Future<void> _reattachExpiredAttachment(String expiredSessionId) async {
    final failedRpc = _rpc;
    if (failedRpc == null || failedRpc.sessionId != expiredSessionId) return;
    final currentState = _state;
    if (currentState is! ConnAttached || currentState.session != session) {
      return;
    }

    await failedRpc.releaseSession();
    if (!identical(_rpc, failedRpc)) return;
    _setState(const ConnConnecting());
    try {
      // The attachment child machine already owns this recovery effect; call
      // the raw operation to avoid recursively joining itself.
      await _attachSession();
    } catch (error) {
      if (identical(_rpc, failedRpc)) {
        _setState(ConnFailed('reattach failed: $error'));
      }
      rethrow;
    }
  }
}
