// ignore_for_file: invalid_use_of_protected_member

part of '../session_screen.dart';

extension _SessionScreenMenuActions on _SessionScreenState {
  Future<void> _newPty() async {
    try {
      final (cols, rows) = _preferredPtySize(_motif);
      await _motif.createPty(cols: cols, rows: rows);
      _focusTerminalAfterTabSwitch();
    } catch (e) {
      if (mounted) {
        showMotifToast(context, 'New terminal failed: $e');
      }
    }
  }

  Future<void> _showRemotePortDialog(MotifClient motif) async {
    final portController = TextEditingController(text: '3000');
    var scheme = 'http';
    try {
      final request = await showDialog<_RemotePortRequest>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('Open remote port'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: portController,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Remote port',
                      hintText: '3000',
                    ),
                    onSubmitted: (_) => Navigator.of(
                      dialogContext,
                    ).maybePop(_remotePortRequest(portController.text, scheme)),
                  ),
                  const SizedBox(height: MotifSpacing.md),
                  DropdownButtonFormField<String>(
                    initialValue: scheme,
                    decoration: const InputDecoration(labelText: 'Open as'),
                    items: const [
                      DropdownMenuItem(value: 'http', child: Text('http')),
                      DropdownMenuItem(value: 'https', child: Text('https')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() => scheme = value);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(
                    dialogContext,
                  ).pop(_remotePortRequest(portController.text, scheme)),
                  child: const Text('Open'),
                ),
              ],
            ),
          );
        },
      );
      if (!mounted || request == null) return;
      await _openRemotePort(motif, request);
    } finally {
      portController.dispose();
    }
  }

  _RemotePortRequest? _remotePortRequest(String rawPort, String scheme) {
    final port = int.tryParse(rawPort.trim());
    if (port == null || port <= 0 || port > 65535) return null;
    return _RemotePortRequest(port: port, scheme: scheme);
  }

  Future<void> _openRemotePort(
    MotifClient motif,
    _RemotePortRequest request,
  ) async {
    if (!_remotePortWebViewSupported()) {
      showMotifToast(context, 'In-app browser is not supported here');
      return;
    }
    try {
      final forwarder = await motif.openRemotePort(
        remotePort: request.port,
        localScheme: request.scheme,
      );
      if (!mounted) {
        await motif.stopRemotePortForwarder(forwarder);
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RemotePortWebViewScreen(
            initialUrl: forwarder.localUrl,
            title: '${request.scheme}://127.0.0.1:${request.port}',
            onClose: () => motif.stopRemotePortForwarder(forwarder),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showMotifToast(context, 'Open port failed: $e');
    }
  }

  bool _remotePortWebViewSupported() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  (int, int) _preferredPtySize(MotifClient motif) {
    final activePty = _activePtyId(motif);
    if (activePty != null) {
      for (final pty in motif.ptys) {
        if (pty.id == activePty && pty.cols > 0 && pty.rows > 0) {
          return (pty.cols, pty.rows);
        }
      }
    }
    for (final pty in motif.ptys) {
      if ((pty.alive ?? true) && pty.cols > 0 && pty.rows > 0) {
        return (pty.cols, pty.rows);
      }
    }
    return (80, 24);
  }

  ViewInfo? _activeView(MotifClient motif) {
    final id = motif.activeViewId;
    if (id != null) {
      for (final v in motif.views) {
        if (v.id == id) return v;
      }
    }
    return motif.views.isEmpty ? null : motif.views.first;
  }

  List<ViewInfo> _mountedViews(MotifClient motif, ViewInfo? activeView) {
    if (_switchingSession) return const [];
    final liveIds = {for (final view in motif.views) view.id};
    _mountedViewIds.removeWhere((id) => !liveIds.contains(id));
    if (activeView != null) _mountedViewIds.add(activeView.id);
    return [
      for (final view in motif.views)
        if (_mountedViewIds.contains(view.id)) view,
    ];
  }

  List<SessionInfo> _sessionsForMenu(MotifServer server, MotifClient motif) {
    return _sessionsForServer(
      server,
      motif,
      currentServerId: widget.serverId,
      currentSession: widget.session,
    );
  }

  List<PopupMenuEntry<_SessionMenuAction>> _sessionMenuEntries(AppState app) {
    final entries = <PopupMenuEntry<_SessionMenuAction>>[
      const PopupMenuItem<_SessionMenuAction>(
        value: _CloseSessionAction(),
        child: Row(
          children: [
            Icon(Icons.close),
            SizedBox(width: 12),
            Text('Close all sessions'),
          ],
        ),
      ),
      const PopupMenuDivider(),
    ];
    for (final group in app.connectedServerClients) {
      final sessions = _sessionsForMenu(group.server, group.client);
      if (sessions.isEmpty) continue;
      entries.add(
        PopupMenuItem<_SessionMenuAction>(
          enabled: false,
          child: Text(
            group.server.name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      );
      for (final session in sessions) {
        final selected =
            group.server.id == widget.serverId &&
            session.name == widget.session;
        entries.add(
          PopupMenuItem<_SessionMenuAction>(
            value: _SwitchSessionAction(group.server.id, session.name),
            enabled: group.client.isLive,
            child: Row(
              children: [
                Icon(selected ? Icons.check : Icons.terminal),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(session.name, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        );
      }
    }
    return entries;
  }

  /// "Close session" leaves *every* open session, not just the current one:
  /// detach all connected clients (one per connected server) and return to the
  /// list. Detach is non-destructive — the sessions keep running server-side.
  Future<void> _closeSession(MotifClient motif) async {
    final app = context.read<AppState>();
    // Only detach clients that are actually attached to a session. A merely
    // connected client (ConnConnected) has no X-Motif-Session, so
    // `session.detach` would be rejected by the server ("missing X-Motif-Session
    // header") and surface a spurious "Close failed" toast.
    final clients = <MotifClient>{
      if (motif.state is ConnAttached) motif,
      for (final group in app.connectedServerClients)
        if (group.client.state is ConnAttached) group.client,
    };
    if (mounted) Navigator.of(context).pop();
    unawaited(
      Future.wait([
        for (final client in clients)
          client.detach().catchError((Object e) {
            if (mounted) showMotifToast(context, 'Close failed: $e');
          }),
      ]),
    );
  }

  Future<void> _switchSession(
    AppState app,
    MotifClient motif,
    String serverId,
    String name,
  ) async {
    if (serverId == widget.serverId && name == widget.session) return;
    try {
      setState(() {
        _switchingSession = true;
        _mountedViewIds.clear();
      });
      final crossServer = serverId != widget.serverId;
      if (crossServer && app.keepSessionWarmOnSwitchAway) {
        // Leave this server attached to its session so switching back is
        // instant (no cold VT replay). Drop it to background so it stops
        // claiming primary / pushing the terminal palette while off-screen.
        motif.setForeground(false);
      } else {
        await motif.detach();
      }
      await app.servers.setActive(serverId);
      if (!mounted) return;
      // Navigate right away; the replacement screen attaches to the target
      // session itself behind its connecting overlay.
      Navigator.of(
        context,
      ).pushReplacement(_sessionSwitchRoute(serverId, name));
    } catch (e) {
      if (!mounted) return;
      setState(() => _switchingSession = false);
      showMotifToast(context, 'Switch failed: $e');
    }
  }

  Future<void> _onSessionMenuSelected(
    AppState app,
    MotifClient motif,
    _SessionMenuAction action,
  ) async {
    switch (action) {
      case _CloseSessionAction():
        await _closeSession(motif);
      case _SwitchSessionAction(:final serverId, :final name):
        await _switchSession(app, motif, serverId, name);
    }
  }

  Future<void> _showSessionMenu(
    AppState app,
    MotifClient motif,
    BuildContext buttonContext,
  ) async {
    try {
      await app.refreshConnectedSessions();
    } catch (_) {
      // Show the cached list if refresh races a transient connection loss.
    }
    if (!mounted || !buttonContext.mounted) return;

    final button = buttonContext.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(buttonContext).overlay?.context.findRenderObject()
            as RenderBox?;
    if (button == null || overlay == null) return;

    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final action = await showMenu<_SessionMenuAction>(
      context: buttonContext,
      position: position,
      items: _sessionMenuEntries(app),
    );
    if (!mounted || action == null) return;
    await _onSessionMenuSelected(app, motif, action);
  }

  Future<void> _showSessionMenuAtOverlay(
    AppState app,
    MotifClient motif,
  ) async {
    try {
      await app.refreshConnectedSessions();
    } catch (_) {
      // Show the cached list if refresh races a transient connection loss.
    }
    if (!mounted) return;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final top = MediaQuery.of(context).padding.top + MotifSpacing.sm;
    final action = await showMenu<_SessionMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        MotifSpacing.sm,
        top,
        overlay.size.width - MotifSpacing.sm,
        overlay.size.height - top,
      ),
      items: _sessionMenuEntries(app),
    );
    if (!mounted || action == null) return;
    await _onSessionMenuSelected(app, motif, action);
  }

  ButtonStyle? _sidebarButtonStyle(MotifColors c, bool selected) {
    if (!selected) return null;
    return IconButton.styleFrom(
      foregroundColor: c.accent,
      backgroundColor: c.accentFill(),
    );
  }
}

class _RemotePortRequest {
  const _RemotePortRequest({required this.port, required this.scheme});

  final int port;
  final String scheme;
}
