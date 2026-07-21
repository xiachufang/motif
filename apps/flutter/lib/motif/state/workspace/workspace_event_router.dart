import '../../log/log.dart';
import '../../models/motif_event.dart';
import '../../models/motif_proto.dart';
import 'terminal/terminal_controller.dart';
import 'view/view_controller.dart';
import 'workspace_content_view_model.dart';
import 'workspace_presence_view_model.dart';

/// Reduces protocol events into the focused ViewModels/controllers owned by a
/// workspace. Hot PTY bytes stay in [TerminalController]'s runtime buffer.
final class WorkspaceEventRouter {
  const WorkspaceEventRouter({
    required this.terminal,
    required this.views,
    required this.content,
    required this.presence,
    required this.onSequence,
  });

  final TerminalController terminal;
  final ViewController views;
  final WorkspaceContentViewModel content;
  final WorkspacePresenceViewModel presence;
  final void Function(int sequence) onSequence;

  void handle(MotifEvent event) {
    final params = event.params;
    final sequence = (params['seq'] as num?)?.toInt();
    if (sequence != null) onSequence(sequence);

    switch (event.method) {
      case 'pty.output':
        terminal.handleOutput(params);
        return;
      case 'pty.exited':
        final id = params['pty_id'] as String?;
        if (id != null) terminal.markExited(id);
      case 'pty.created':
        terminal.addCreated(
          PtyInfo.fromJson((params['info'] as Map).cast<String, Object?>()),
        );
      case 'pty.resize':
        final id = params['pty_id'] as String?;
        if (id != null) {
          terminal.updatePty(
            id,
            (pty) => pty.copyWith(
              cols: (params['cols'] as num?)?.toInt(),
              rows: (params['rows'] as num?)?.toInt(),
            ),
          );
        }
      case 'pty.cwd_changed':
        final id = params['pty_id'] as String?;
        if (id != null) {
          terminal.updatePty(
            id,
            (pty) => pty.copyWith(cwd: params['cwd'] as String?),
          );
        }
      case 'pty.command_started':
        final id = params['pty_id'] as String?;
        final text = params['text'] as String?;
        if (id != null && text != null && text.isNotEmpty) {
          terminal.viewModel.runningCommand[id] = text;
        }
      case 'pty.command_finished':
        final id = params['pty_id'] as String?;
        if (id != null) terminal.viewModel.runningCommand.remove(id);
      case 'pty.shell_bootstrapped':
        final id = params['pty_id'] as String?;
        if (id != null) {
          terminal.viewModel.shellKind[id] = ShellKind.fromWire(
            params['shell'],
          );
        }
      case 'pty.shell_context':
        final id = params['pty_id'] as String?;
        if (id != null && params['ctx'] is Map) {
          terminal.viewModel.shellContext[id] = ShellContext.fromMap(
            (params['ctx'] as Map).map(
              (key, value) => MapEntry('$key', '$value'),
            ),
          );
        }
      case 'view.opened':
        views.handleOpened(
          ViewInfo.fromJson((params['view'] as Map).cast<String, Object?>()),
        );
      case 'view.closed':
        views.handleClosed(params['view_id'] as String?);
      case 'view.active_changed':
        final id = params['view_id'] as String?;
        views.handleActiveChanged(id);
        Log.i('event active_changed view=$id', name: 'motif.view');
      case 'view.moved':
        views.handleMoved(
          ((params['order'] as List?) ?? []).map((entry) => '$entry'),
        );
      case 'tree.changed':
        content.invalidateTree();
      case 'git.changed':
        content.invalidateGit();
      case 'session.theme_changed':
        presence.sessionTheme = params['theme'] as String?;
      case 'client.joined':
        final client = ClientInfo.fromJson(params);
        final index = presence.clients.indexWhere(
          (candidate) => candidate.id == client.id,
        );
        if (index < 0) {
          presence.clients.add(client);
        } else {
          presence.clients[index] = client;
        }
      case 'client.left':
        final id = params['client_id'] as String?;
        presence.clients.removeWhere((client) => client.id == id);
      case 'notification':
        presence.latestNotification = MotifNotification.fromJson(params);
    }
  }
}
