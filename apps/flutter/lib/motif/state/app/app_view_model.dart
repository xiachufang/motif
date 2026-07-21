import 'package:flutter_observation/flutter_observation.dart';

import 'app_ui_state.dart';
import '../embedded/embedded_server_view_model.dart';
import '../server/server_view_models.dart';
import '../persistence/store_view_models.dart';
import '../platform/tailscale_view_model.dart';

part 'app_view_model.g.dart';

@ObservableModel()
class PreferencesViewModel extends _$PreferencesViewModel {
  PreferencesViewModel({
    @ObservationReadOnly() required TerminalPreferencesViewModel terminal,
    @ObservationReadOnly() required QuickCommandViewModel quickCommands,
    @ObservationReadOnly() required PushPreferencesViewModel push,
  }) : super(terminal, quickCommands, push);
}

@ObservableModel()
class PlatformViewModel extends _$PlatformViewModel {
  PlatformViewModel({
    @ObservationReadOnly() required TailscaleViewModel tailscale,
    @ObservationReadOnly() required EmbeddedServerViewModel? embeddedServer,
  }) : super(tailscale, embeddedServer);
}

@ObservableModel()
class AppViewModel extends _$AppViewModel {
  AppViewModel({
    @ObservationReadOnly() required AppShellViewModel shell,
    @ObservationReadOnly() required PreferencesViewModel preferences,
    @ObservationReadOnly() required PlatformViewModel platform,
    @ObservationReadOnly() required ServerRegistryViewModel servers,
  }) : super(shell, preferences, platform, servers);
}
