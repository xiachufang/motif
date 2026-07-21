import 'package:flutter_observation/flutter_observation.dart';

import '../../models/settings.dart';
import '../server/push_runtime_state.dart';

part 'store_view_models.g.dart';

@ObservableModel()
class PushPreferencesViewModel extends _$PushPreferencesViewModel {
  PushPreferencesViewModel({
    PushRuntimeState runtime = const PushRuntimeState.initial(),
    bool enabled = true,
    @ObservationReadOnly() required ObservableSet<String> mutedSessions,
  }) : super(runtime, enabled, mutedSessions);
}

@ObservableModel()
class ServerProfilesViewModel extends _$ServerProfilesViewModel {
  ServerProfilesViewModel({
    @ObservationReadOnly() required ObservableList<MotifServer> servers,
    String? activeId,
  }) : super(servers, activeId);
}

@ObservableModel()
class TerminalPreferencesViewModel extends _$TerminalPreferencesViewModel {
  TerminalPreferencesViewModel({
    TerminalSettings settings = const TerminalSettings(),
  }) : super(settings);
}

@ObservableModel()
class QuickCommandViewModel extends _$QuickCommandViewModel {
  QuickCommandViewModel({
    @ObservationReadOnly() required ObservableList<QuickCommand> commands,
    @ObservationReadOnly() required ObservableList<QuickCommandSet> sets,
  }) : super(commands, sets);
}
