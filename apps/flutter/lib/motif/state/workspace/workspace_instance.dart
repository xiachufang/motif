import 'workspace_lifecycle_controller.dart';
import 'remote_port/remote_port_controller.dart';
import 'session_attachment.dart';
import 'terminal/terminal_controller.dart';
import 'view/view_controller.dart';
import 'workspace_api.dart';
import 'connection/workspace_connection_controller.dart';
import 'workspace_view_model.dart';

/// Runtime resources for one exact `(serverId, session)` identity.
///
/// This is a composition root, not a feature facade: callers select the
/// focused controller they need instead of asking the instance to forward
/// commands.
final class WorkspaceInstance {
  WorkspaceInstance({
    required this.key,
    required this.viewModel,
    required this.connection,
    required this.lifecycle,
    required this.attachment,
    required this.terminal,
    required this.views,
    required this.remotePorts,
    required this.workspace,
  });

  factory WorkspaceInstance.compose({
    required WorkspaceKey key,
    required WorkspaceConnectionController connection,
    required WorkspaceLifecycleController lifecycle,
  }) {
    if (connection.session != key.session) {
      throw ArgumentError.value(
        connection.session,
        'connection.session',
        'must match WorkspaceInstance key session ${key.session}',
      );
    }
    return WorkspaceInstance(
      key: key,
      viewModel: WorkspaceViewModel(
        serverId: key.serverId,
        session: key.session,
        connection: connection.connection,
        terminal: connection.terminal.viewModel,
        views: connection.viewsController.viewModel,
        remotePorts: connection.remotePorts.viewModel,
        content: connection.content,
        presence: connection.presence,
      ),
      connection: connection,
      lifecycle: lifecycle,
      attachment: connection,
      terminal: connection.terminal,
      views: connection.viewsController,
      remotePorts: connection.remotePorts,
      workspace: connection.workspace,
    );
  }

  final WorkspaceKey key;
  final WorkspaceViewModel viewModel;
  final WorkspaceConnectionController connection;
  final WorkspaceLifecycleController lifecycle;
  final SessionAttachment attachment;
  final TerminalController terminal;
  final ViewController views;
  final RemotePortController remotePorts;
  final WorkspaceApi workspace;

  bool get isLive => viewModel.connection.transportAvailable;

  Future<void> close() => lifecycle.disconnect();

  void dispose() {
    lifecycle.dispose();
    connection.dispose();
  }

  Future<void> closeAndDispose() async {
    try {
      await close();
    } finally {
      dispose();
    }
  }
}
