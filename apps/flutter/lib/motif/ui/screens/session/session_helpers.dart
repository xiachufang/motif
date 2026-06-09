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

Route<void> _sessionSwitchRoute(String serverId, String session) {
  return PageRouteBuilder<void>(
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
    builder: (_) => AlertDialog(
      title: const Text('Close running terminal?'),
      content: Text('A command is still running:\n\n$command'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
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
