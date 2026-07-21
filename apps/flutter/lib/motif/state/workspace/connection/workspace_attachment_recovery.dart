part of 'workspace_connection_controller.dart';

/// Attachment recovery shared by focused feature transports.
extension _WorkspaceConnectionControllerRecovery
    on WorkspaceConnectionController {
  Future<RpcClient?> _waitForAttachedRpc() async {
    final pending = _attachInFlight;
    if (pending != null) {
      try {
        await pending;
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

    final recovered = await _recoverExpiredAttachment(rpc, attemptedSessionId);
    if (recovered == null) return;
    await operation(recovered);
  }

  Future<RpcClient?> _recoverExpiredAttachment(
    RpcClient failedRpc,
    String expiredSessionId,
  ) async {
    if (failedRpc.sessionId != expiredSessionId) {
      return _waitForAttachedRpc();
    }
    final existing = _attachmentRecovery;
    if (existing != null) {
      await existing;
      return _waitForAttachedRpc();
    }

    late final Future<void> recovery;
    recovery = _reattachExpiredAttachment(failedRpc, expiredSessionId)
        .whenComplete(() {
          if (identical(_attachmentRecovery, recovery)) {
            _attachmentRecovery = null;
          }
        });
    _attachmentRecovery = recovery;
    await recovery;
    return _waitForAttachedRpc();
  }

  Future<void> _reattachExpiredAttachment(
    RpcClient failedRpc,
    String expiredSessionId,
  ) async {
    if (!identical(_rpc, failedRpc) ||
        failedRpc.sessionId != expiredSessionId) {
      return;
    }
    final currentState = _state;
    if (currentState is! ConnAttached) return;
    if (currentState.session != session) return;

    await failedRpc.releaseSession();
    if (!identical(_rpc, failedRpc)) return;
    _setState(const ConnConnecting());
    try {
      await attach();
    } catch (error) {
      if (identical(_rpc, failedRpc)) {
        _setState(ConnFailed('reattach failed: $error'));
      }
      rethrow;
    }
  }
}
