import 'package:flutter_observation/flutter_observation.dart';

import '../../../models/motif_proto.dart';

part 'terminal_view_model.g.dart';

@ObservableModel()
class TerminalViewModel extends _$TerminalViewModel {
  TerminalViewModel({
    @ObservationReadOnly() required ObservableList<PtyInfo> ptys,
    @ObservationReadOnly()
    required ObservableMap<String, String> runningCommand,
    @ObservationReadOnly() required ObservableMap<String, ShellKind> shellKind,
    @ObservationReadOnly()
    required ObservableMap<String, ShellContext> shellContext,
  }) : super(ptys, runningCommand, shellKind, shellContext);
}
