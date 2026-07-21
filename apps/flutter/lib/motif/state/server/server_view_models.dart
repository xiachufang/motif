import 'package:flutter_observation/flutter_observation.dart';

import '../../models/settings.dart';
import '../connection/connection_state.dart';
import 'device_registration_view_model.dart';
import 'server_runtime_state.dart';
import 'session_catalog_view_model.dart';
import '../workspace/workspace_view_model.dart';

part 'server_view_models.g.dart';

enum ServerAccessPhase { idle, resolving, ready, blocked, failed }

@ObservableModel()
class ServerAccessViewModel extends _$ServerAccessViewModel {
  ServerAccessViewModel({
    ServerRuntimeState runtime = const ServerRuntimeDisconnected(),
    ServerAccessPhase phase = ServerAccessPhase.idle,
    TransportViewState? transport,
    ConnectionBlocker? blocker,
    String? error,
    String? resolvedEndpoint,
  }) : super(runtime, phase, transport, blocker, error, resolvedEndpoint);

  bool get isReady => runtime.isOnline;
}

@ObservableModel()
class WorkspaceRegistryViewModel extends _$WorkspaceRegistryViewModel {
  WorkspaceRegistryViewModel({
    String? activeSession,
    @ObservationReadOnly() required ObservableList<String> warmOrder,
    @ObservationReadOnly()
    required ObservableMap<String, WorkspaceViewModel> retained,
  }) : super(activeSession, warmOrder, retained);

  WorkspaceViewModel? get active =>
      activeSession == null ? null : retained[activeSession];

  bool isWarm(String session) =>
      session != activeSession && retained.containsKey(session);
}

@ObservableModel()
class ServerViewModel extends _$ServerViewModel {
  ServerViewModel({
    required MotifServer profile,
    @ObservationReadOnly() required ServerAccessViewModel access,
    @ObservationReadOnly() required SessionCatalogViewModel sessions,
    @ObservationReadOnly() required DeviceRegistrationViewModel device,
    @ObservationReadOnly() required WorkspaceRegistryViewModel workspaces,
  }) : super(profile, access, sessions, device, workspaces);

  String get id => profile.id;

  ServerKind get kind => profile.kind;
}

@ObservableModel()
class ServerRegistryViewModel extends _$ServerRegistryViewModel {
  ServerRegistryViewModel({
    String? activeServerId,
    @ObservationReadOnly() required ObservableList<String> order,
    @ObservationReadOnly()
    required ObservableMap<String, ServerViewModel> entries,
  }) : super(activeServerId, order, entries);

  ServerViewModel? get active =>
      activeServerId == null ? null : entries[activeServerId];
}
