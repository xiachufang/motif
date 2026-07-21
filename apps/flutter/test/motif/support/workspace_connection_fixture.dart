import 'package:flutter_observation/flutter_observation.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_controller.dart';

/// Test-only snapshot helpers. Production code reads and mutates the focused
/// Terminal/View/Presence ViewModels directly.
extension WorkspaceConnectionFixtureState on WorkspaceConnectionController {
  ObservableList<PtyInfo> get ptys => terminal.viewModel.ptys;

  set ptys(Iterable<PtyInfo> value) {
    terminal.viewModel.ptys.replaceRange(
      0,
      terminal.viewModel.ptys.length,
      value,
    );
  }

  ObservableList<ViewInfo> get views => viewsController.viewModel.items;

  set views(Iterable<ViewInfo> value) {
    viewsController.viewModel.items.replaceRange(
      0,
      viewsController.viewModel.items.length,
      value,
    );
  }

  String? get activeViewId => viewsController.viewModel.activeViewId;

  set activeViewId(String? value) {
    viewsController.viewModel.activeViewId = value;
  }

  ObservableMap<String, String> get runningCommand =>
      terminal.viewModel.runningCommand;
}
