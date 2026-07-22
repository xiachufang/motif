// ignore_for_file: invalid_use_of_protected_member

part of '../session_screen.dart';

extension _SessionScreenMenuActions on _SessionScreenState {
  Future<void> _newPty() async {
    try {
      final (cols, rows) = _preferredPtySize();
      await _terminalController.create(cols: cols, rows: rows);
      _focusTerminalAfterTabSwitch();
    } catch (e) {
      if (mounted) {
        showMotifToast(context, 'New terminal failed: $e');
      }
    }
  }

  Future<void> _showRemotePortMappings(RemotePortController controller) async {
    if (!_remotePortWebViewSupported()) {
      showMotifToast(context, 'In-app browser is not supported here');
      return;
    }
    await showRemotePortMappingsSheet(context, controller);
  }

  bool _remotePortWebViewSupported() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  (int, int) _preferredPtySize() {
    final ptys = _terminalController.viewModel.ptys;
    final activePty = _activePtyId();
    if (activePty != null) {
      for (final pty in ptys) {
        if (pty.id == activePty && pty.cols > 0 && pty.rows > 0) {
          return (pty.cols, pty.rows);
        }
      }
    }
    for (final pty in ptys) {
      if ((pty.alive ?? true) && pty.cols > 0 && pty.rows > 0) {
        return (pty.cols, pty.rows);
      }
    }
    return (80, 24);
  }

  List<ViewInfo> _mountedViews(ViewInfo? activeView) {
    if (_switchingSession) return const [];
    final items = _workspaceState.views.items;
    final liveIds = {for (final view in items) view.id};
    _mountedViewIds.removeWhere((id) => !liveIds.contains(id));
    if (activeView != null) _mountedViewIds.add(activeView.id);
    return [
      for (final view in items)
        if (_mountedViewIds.contains(view.id)) view,
    ];
  }

  /// "Close session" leaves *every* open session, not just the current one:
  /// detach all connected clients (one per connected server) and return to the
  /// list. Detach is non-destructive — the sessions keep running server-side.
  Future<void> _closeSession() async {
    final app = readObservationScope<AppState>(context);
    if (mounted) Navigator.of(context).pop();
    unawaited(
      app.detachAllSessions().catchError((Object e) {
        if (mounted) showMotifToast(context, 'Close failed: $e');
      }),
    );
  }

  Future<void> _switchSession(
    AppState app,
    String serverId,
    String name,
  ) async {
    if (serverId == widget.serverId && name == widget.session) return;
    try {
      final keepWarm = app.keepSessionWarmOnSwitchAway;
      if (!keepWarm) {
        setState(() {
          _switchingSession = true;
          _mountedViewIds.clear();
        });
      }
      app.prepareWorkspaceSelection(
        fromServerId: widget.serverId,
        fromSession: widget.session,
        toServerId: serverId,
        toSession: name,
      );
      if (!mounted) return;
      if (keepWarm && widget.onWorkspaceSelected != null) {
        widget.onWorkspaceSelected!(serverId, name);
        return;
      }
      // Navigate immediately; attach/restore runs behind the target screen's
      // non-modal connecting banner, leaving the rest of the page responsive.
      Navigator.of(
        context,
      ).pushReplacement(_sessionSwitchRoute(serverId, name));
    } catch (e) {
      if (!mounted) return;
      setState(() => _switchingSession = false);
      showMotifToast(context, 'Switch failed: $e');
    }
  }

  Future<void> _switchSessionFromMobileDrawer(
    AppState app,
    String serverId,
    String session,
  ) async {
    await _closeMobileDrawers();
    if (mounted) await _switchSession(app, serverId, session);
  }

  Future<void> _closeAllSessionsFromMobileDrawer() async {
    await _closeMobileDrawers();
    if (mounted) await _closeSession();
  }

  ButtonStyle? _sidebarButtonStyle(
    BuildContext context,
    MotifColors c,
    bool selected,
  ) {
    if (!selected) return null;
    return context.iconButtonStyle(foregroundColor: c.accent);
  }
}
