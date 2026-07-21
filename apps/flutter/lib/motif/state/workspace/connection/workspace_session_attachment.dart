part of 'workspace_connection_controller.dart';

/// Fixed-workspace attachment lifecycle.
extension _WorkspaceConnectionControllerAttachment
    on WorkspaceConnectionController {
  Future<void> _attachSession() async {
    final rpc = _rpc;
    if (rpc == null) throw const RpcException('not connected');
    await remotePorts.stopAll();
    final params = <String, Object?>{
      'name': session,
      'last_seq': ?resumeSequence,
    };
    // Backgrounded clients don't push palette/theme (mirrors iOS), so only
    // advertise it while foreground.
    if (isForeground) {
      params['term_fg'] = termFg;
      params['term_bg'] = termBg;
      params['theme'] = termTheme;
    }
    final body = await rpc.call('session.attach', params);
    final result = AttachResult.fromJson(body);

    terminal.replacePtys(result.ptys);
    // Cold attach replays a VT snapshot with no shell-integration markers, so
    // the client-side OSC parser can't discover a command that was already
    // running. Seed it from the server's authoritative state and prime the
    // per-PTY shell parser so the next live `command end` marker clears it.
    final shellPrimes = <Future<void>>[];
    for (final pty in terminal.viewModel.ptys) {
      final running = pty.runningCommand;
      if (running != null && running.isNotEmpty) {
        terminal.viewModel.runningCommand[pty.id] = running;
        shellPrimes.add(rpc.primePtyRunning(pty.id, running));
      }
    }
    await Future.wait(shellPrimes);
    viewsController.replaceSnapshot(result.views, result.activeView);
    presence.clients.replaceRange(0, presence.clients.length, result.clients);
    lastSeq = result.lastSeq ?? 0;
    presence.sessionTheme = result.theme;
    resumeSequence = null;

    _setState(ConnAttached(session));
    terminal.onSessionAttached();
    Log.i(
      'attach session=$session ptys=${terminal.viewModel.ptys.map(WorkspaceConnectionController._describePty).join(",")} '
      'views=${_viewState.items.map(WorkspaceConnectionController._describeView).join(",")} '
      'active=${_viewState.activeViewId} lastSeq=$lastSeq',
      name: 'motif.session',
    );

    _reclaimPrimary();
  }

  Future<void> _detachImpl() async {
    _attachmentRuntime.reset();
    await remotePorts.stopAll();
    await _rpc?.call('session.detach');
    resumeSequence = null;
    pendingLocalViewId = null;
    _clearSessionState();
    _setState(const ConnConnected());
  }

  String? _activePtyId() => _ptyIdForViewId(_viewState.activeViewId);

  Set<String> _liveTabPtyIds() {
    final byId = {for (final pty in terminal.viewModel.ptys) pty.id: pty};
    final ids = <String>{};
    for (final view in _viewState.items) {
      final spec = view.spec;
      if (spec is! PtyViewSpec) continue;
      final pty = byId[spec.ptyId];
      if (pty == null || (pty.alive ?? true)) ids.add(spec.ptyId);
    }
    return ids;
  }

  String? _ptyIdForViewId(String? viewId) {
    if (viewId == null) return null;
    for (final view in _viewState.items) {
      if (view.id == viewId && view.spec is PtyViewSpec) {
        return (view.spec as PtyViewSpec).ptyId;
      }
    }
    return null;
  }
}
