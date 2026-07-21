import 'package:flutter/widgets.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../update/desktop_update_service.dart';
import 'app_state.dart';
import '../embedded/embedded_server_service.dart';
import '../workspace/remote_port/remote_port_controller.dart';
import '../workspace/session_attachment.dart';
import '../workspace/terminal/terminal_controller.dart';
import '../workspace/view/view_controller.dart';
import '../workspace/workspace_api.dart';
import '../workspace/workspace_view_model.dart';

/// Injects Motif's process-wide dependencies through Observation scopes.
///
/// The scopes only expose existing instances. Ownership and disposal remain
/// with the bootstrap/runtime that created them.
final class MotifScope extends StatelessWidget {
  const MotifScope({
    required this.appState,
    required this.child,
    this.embeddedServer,
    this.desktopUpdateService,
    super.key,
  });

  final AppState appState;
  final EmbeddedServerService? embeddedServer;
  final DesktopUpdateService? desktopUpdateService;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget scoped = ObservationScope<DesktopUpdateService?>(
      value: desktopUpdateService,
      child: child,
    );
    final server = embeddedServer ?? appState.embeddedServer;
    if (server != null) {
      scoped = ObservationScope<EmbeddedServerService>(
        value: server,
        child: scoped,
      );
    }
    return ObservationScope<AppState>(value: appState, child: scoped);
  }
}

/// A named-argument wrapper around [ObservationScope] for focused widget tests
/// and feature subtrees that only need one scoped value.
final class MotifValueScope<T> extends StatelessWidget {
  const MotifValueScope({required this.value, required this.child, super.key});

  final T value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ObservationScope<T>(value: value, child: child);
  }
}

/// Injects only the focused capabilities used by a workspace subtree.
final class WorkspaceScope extends StatelessWidget {
  const WorkspaceScope({
    required this.viewModel,
    required this.attachment,
    required this.terminal,
    required this.views,
    required this.workspace,
    required this.remotePorts,
    required this.child,
    super.key,
  });

  final WorkspaceViewModel viewModel;
  final SessionAttachment attachment;
  final TerminalController terminal;
  final ViewController views;
  final WorkspaceApi workspace;
  final RemotePortController remotePorts;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ObservationScope<WorkspaceViewModel>(
      value: viewModel,
      child: ObservationScope<SessionAttachment>(
        value: attachment,
        child: ObservationScope<TerminalController>(
          value: terminal,
          child: ObservationScope<ViewController>(
            value: views,
            child: ObservationScope<WorkspaceApi>(
              value: workspace,
              child: ObservationScope<RemotePortController>(
                value: remotePorts,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reads a scoped dependency without registering an inherited dependency.
///
/// Use [ObservationScope.of] during an Observation build. This helper is only
/// for lifecycle methods such as `initState` and imperative event callbacks.
T readObservationScope<T>(BuildContext context) {
  final element = context
      .getElementForInheritedWidgetOfExactType<ObservationScope<T>>();
  if (element == null) {
    throw FlutterError('No ObservationScope<$T> found in this context.');
  }
  return (element.widget as ObservationScope<T>).value;
}
