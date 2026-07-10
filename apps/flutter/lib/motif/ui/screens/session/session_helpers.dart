part of '../session_screen.dart';

sealed class _SessionMenuAction {
  const _SessionMenuAction();
}

class _CloseSessionAction extends _SessionMenuAction {
  const _CloseSessionAction();
}

class _SwitchSessionAction extends _SessionMenuAction {
  final String serverId;
  final String name;
  const _SwitchSessionAction(this.serverId, this.name);
}

class _TabInputState {
  _TabInputState(String id)
    : controller = TextEditingController(),
      focusNode = FocusNode(debugLabel: 'Motif input bar $id'),
      groupId = Object();

  final TextEditingController controller;
  final FocusNode focusNode;
  final Object groupId;
}

extension _SessionScreenTabInputs on _SessionScreenState {
  TextEditingController get _input => _activeInputState.controller;

  _TabInputState get _activeInputState =>
      _inputStateForView(_activeView(_motif)?.id);

  _TabInputState _createInputState(String id) {
    final input = _TabInputState(id);
    input.controller.addListener(_onInputChanged);
    return input;
  }

  _TabInputState _inputStateForView(String? viewId) {
    if (viewId == null || viewId.isEmpty) return _fallbackInput;
    return _tabInputs.putIfAbsent(viewId, () => _createInputState(viewId));
  }

  TextEditingController? _inputControllerForView(String? viewId) {
    if (viewId == null || viewId.isEmpty) return _fallbackInput.controller;
    return _tabInputs[viewId]?.controller;
  }

  void _reconcileTabInputs(MotifClient motif, ViewInfo? activeView) {
    final liveIds = {for (final view in motif.views) view.id};
    if (activeView != null) liveIds.add(activeView.id);
    final staleAppleDocumentIds = [
      for (final id in _appleInputDocumentIds)
        if (!liveIds.contains(id)) id,
    ];
    for (final id in staleAppleDocumentIds) {
      _disposeAppleInputDocument(id);
    }
    final staleIds = [
      for (final id in _tabInputs.keys)
        if (!liveIds.contains(id)) id,
    ];
    for (final id in staleIds) {
      final input = _tabInputs.remove(id);
      if (input != null) _disposeInputState(input);
      if (_asrInputViewId == id) _asrInputViewId = null;
    }
  }

  void _syncAppleInputDocument(String? viewId) {
    if (viewId == null ||
        viewId.isEmpty ||
        _lastAppleInputDocumentId == viewId) {
      return;
    }
    _lastAppleInputDocumentId = viewId;
    final isNewDocument = _appleInputDocumentIds.add(viewId);
    unawaited(
      AppleInputDocument.activate(
        viewId,
        defaultEnglish: isNewDocument,
      ).catchError((_) {}),
    );
  }

  void _disposeAppleInputDocument(String id) {
    _appleInputDocumentIds.remove(id);
    if (_lastAppleInputDocumentId == id) _lastAppleInputDocumentId = null;
    unawaited(AppleInputDocument.dispose(id).catchError((_) {}));
  }

  void _disposeInputState(_TabInputState input) {
    input.controller.removeListener(_onInputChanged);
    input.controller.dispose();
    input.focusNode.dispose();
  }
}

Route<void> _sessionSwitchRoute(String serverId, String session) {
  return PageRouteBuilder<void>(
    settings: RouteSettings(name: sessionRouteName(serverId, session)),
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, _, _) =>
        SessionScreen(serverId: serverId, session: session),
    transitionsBuilder: (context, animation, _, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.98, end: 1).animate(curve),
          child: child,
        ),
      );
    },
  );
}

Future<void> _closeViewWithConfirmation(
  BuildContext context,
  MotifClient motif,
  ViewInfo view,
) async {
  final runningCommand = switch (view.spec) {
    PtyViewSpec(:final ptyId) => motif.runningCommand[ptyId],
    _ => null,
  };
  if (runningCommand != null && runningCommand.isNotEmpty) {
    final shouldClose = await _confirmCloseRunningTab(context, runningCommand);
    if (!shouldClose) return;
  }
  try {
    unawaited(
      motif.closeView(view.id).catchError((Object e) {
        if (context.mounted) {
          showMotifToast(context, 'Close tab failed: $e');
        }
      }),
    );
  } catch (e) {
    if (context.mounted) {
      showMotifToast(context, 'Close tab failed: $e');
    }
  }
}

Future<bool> _confirmCloseRunningTab(
  BuildContext context,
  String command,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Close running terminal?'),
      content: Text('A command is still running:\n\n$command'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Close tab'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

List<SessionInfo> _sessionsForServer(
  MotifServer server,
  MotifClient motif, {
  required String currentServerId,
  required String currentSession,
}) {
  final sessions = [...motif.sessions];
  if (server.id == currentServerId &&
      !sessions.any((s) => s.name == currentSession)) {
    sessions.insert(0, SessionInfo(name: currentSession));
  }
  return sessions;
}

bool get _usesCommandShortcuts =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

List<int> _terminalBytes(String text, {bool enter = false}) => [
  ...utf8.encode(text),
  if (enter) 0x0d,
];

String _primaryShortcutLabel(String key, {bool shift = false}) {
  final primary = _usesCommandShortcuts ? 'Cmd' : 'Ctrl';
  return shift ? '$primary+Shift+$key' : '$primary+$key';
}

/// Equality key for tab-bar rebuilds (views / active / labels / live).
({String views, String? activeViewId, String labels, bool isLive})
_tabBarSelectKey(MotifClient motif) {
  final labels = <String>[];
  for (final view in motif.views) {
    labels.add(switch (view.spec) {
      PtyViewSpec(:final ptyId) =>
        motif.runningCommand[ptyId] ??
            motif.ptys
                .where((p) => p.id == ptyId)
                .map((p) => p.cwd?.split('/').last)
                .firstOrNull ??
            'shell',
      PreviewViewSpec(:final path) => path.split('/').last,
      DiffViewSpec(:final path) => path?.split('/').last ?? 'diff',
      ImageViewSpec(:final path) => path.split('/').last,
      OtherViewSpec(:final typeName) => typeName,
    });
  }
  return (
    views: motif.views.map((v) => v.id).join(','),
    activeViewId: motif.activeViewId,
    labels: labels.join('\u{1e}'),
    isLive: motif.isLive,
  );
}

/// Equality key for pane-stack rebuilds.
({String views, String? activeViewId, String? cwd}) _paneSelectKey(
  MotifClient motif,
) => (
  views: motif.views.map((v) => '${v.id}:${v.spec.runtimeType}').join(','),
  activeViewId: motif.activeViewId,
  cwd: motif.activeCwd,
);

/// Equality key for bottom bar / quick-command rebuilds.
({String? activeViewId, String? runningProgram}) _bottomBarSelectKey(
  MotifClient motif,
) {
  final activeId = motif.activeViewId;
  ViewInfo? active;
  if (activeId != null) {
    for (final v in motif.views) {
      if (v.id == activeId) {
        active = v;
        break;
      }
    }
  }
  active ??= motif.views.isEmpty ? null : motif.views.first;
  final ptyId = switch (active?.spec) {
    PtyViewSpec(:final ptyId) => ptyId,
    _ => null,
  };
  return (
    activeViewId: active?.id,
    runningProgram: ptyId == null ? null : motif.runningCommand[ptyId],
  );
}

/// Equality key for connected-sessions sidebar (ignores view/tick noise).
({String servers, String sessions}) _connectedSessionsSelectKey(AppState app) {
  final groups = app.connectedServerClients;
  return (
    servers: jsonEncode([
      for (final g in groups)
        {'id': g.server.id, 'name': g.server.name, 'live': g.client.isLive},
    ]),
    sessions: jsonEncode([
      for (final g in groups)
        {
          'server': g.server.id,
          'sessions': [for (final s in g.client.sessions) s.name],
        },
    ]),
  );
}
