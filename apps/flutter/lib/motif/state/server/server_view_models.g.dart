// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_view_models.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$ServerAccessViewModel with ObservableModelMixin {
  _$ServerAccessViewModel(
    ServerRuntimeState runtime,
    ServerAccessPhase phase,
    TransportViewState? transport,
    ConnectionBlocker? blocker,
    String? error,
    String? resolvedEndpoint,
  ) : _runtime = runtime,
      _phase = phase,
      _transport = transport,
      _blocker = blocker,
      _error = error,
      _resolvedEndpoint = resolvedEndpoint {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_runtimeKey, () => _runtime);
      observationRegisterDebugProperty(_phaseKey, () => _phase);
      observationRegisterDebugProperty(_transportKey, () => _transport);
      observationRegisterDebugProperty(_blockerKey, () => _blocker);
      observationRegisterDebugProperty(_errorKey, () => _error);
      observationRegisterDebugProperty(
        _resolvedEndpointKey,
        () => _resolvedEndpoint,
      );
    }
  }
  final ObservationKey<ServerRuntimeState> _runtimeKey =
      ObservationKey<ServerRuntimeState>('ServerAccessViewModel.runtime');
  ServerRuntimeState _runtime;

  ServerRuntimeState get runtime {
    observationAccess(_runtimeKey);
    return _runtime;
  }

  set runtime(ServerRuntimeState value) {
    if (_runtime == value) return;
    observationMutation(_runtimeKey, () {
      _runtime = value;
    });
  }

  final ObservationKey<ServerAccessPhase> _phaseKey =
      ObservationKey<ServerAccessPhase>('ServerAccessViewModel.phase');
  ServerAccessPhase _phase;

  ServerAccessPhase get phase {
    observationAccess(_phaseKey);
    return _phase;
  }

  set phase(ServerAccessPhase value) {
    if (_phase == value) return;
    observationMutation(_phaseKey, () {
      _phase = value;
    });
  }

  final ObservationKey<TransportViewState?> _transportKey =
      ObservationKey<TransportViewState?>('ServerAccessViewModel.transport');
  TransportViewState? _transport;

  TransportViewState? get transport {
    observationAccess(_transportKey);
    return _transport;
  }

  set transport(TransportViewState? value) {
    if (_transport == value) return;
    observationMutation(_transportKey, () {
      _transport = value;
    });
  }

  final ObservationKey<ConnectionBlocker?> _blockerKey =
      ObservationKey<ConnectionBlocker?>('ServerAccessViewModel.blocker');
  ConnectionBlocker? _blocker;

  ConnectionBlocker? get blocker {
    observationAccess(_blockerKey);
    return _blocker;
  }

  set blocker(ConnectionBlocker? value) {
    if (_blocker == value) return;
    observationMutation(_blockerKey, () {
      _blocker = value;
    });
  }

  final ObservationKey<String?> _errorKey = ObservationKey<String?>(
    'ServerAccessViewModel.error',
  );
  String? _error;

  String? get error {
    observationAccess(_errorKey);
    return _error;
  }

  set error(String? value) {
    if (_error == value) return;
    observationMutation(_errorKey, () {
      _error = value;
    });
  }

  final ObservationKey<String?> _resolvedEndpointKey = ObservationKey<String?>(
    'ServerAccessViewModel.resolvedEndpoint',
  );
  String? _resolvedEndpoint;

  String? get resolvedEndpoint {
    observationAccess(_resolvedEndpointKey);
    return _resolvedEndpoint;
  }

  set resolvedEndpoint(String? value) {
    if (_resolvedEndpoint == value) return;
    observationMutation(_resolvedEndpointKey, () {
      _resolvedEndpoint = value;
    });
  }
}

abstract class _$WorkspaceRegistryViewModel with ObservableModelMixin {
  _$WorkspaceRegistryViewModel(
    String? activeSession,
    ObservableList<String> warmOrder,
    ObservableMap<String, WorkspaceViewModel> retained,
  ) : _activeSession = activeSession,
      _warmOrder = warmOrder,
      _retained = retained {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_activeSessionKey, () => _activeSession);
      observationRegisterDebugProperty(_warmOrderKey, () => _warmOrder);
      observationRegisterDebugProperty(_retainedKey, () => _retained);
    }
  }
  final ObservationKey<String?> _activeSessionKey = ObservationKey<String?>(
    'WorkspaceRegistryViewModel.activeSession',
  );
  String? _activeSession;

  String? get activeSession {
    observationAccess(_activeSessionKey);
    return _activeSession;
  }

  set activeSession(String? value) {
    if (_activeSession == value) return;
    observationMutation(_activeSessionKey, () {
      _activeSession = value;
    });
  }

  final ObservationKey<ObservableList<String>> _warmOrderKey =
      ObservationKey<ObservableList<String>>(
        'WorkspaceRegistryViewModel.warmOrder',
      );
  final ObservableList<String> _warmOrder;

  ObservableList<String> get warmOrder {
    observationAccess(_warmOrderKey);
    return _warmOrder;
  }

  final ObservationKey<ObservableMap<String, WorkspaceViewModel>> _retainedKey =
      ObservationKey<ObservableMap<String, WorkspaceViewModel>>(
        'WorkspaceRegistryViewModel.retained',
      );
  final ObservableMap<String, WorkspaceViewModel> _retained;

  ObservableMap<String, WorkspaceViewModel> get retained {
    observationAccess(_retainedKey);
    return _retained;
  }
}

abstract class _$ServerViewModel with ObservableModelMixin {
  _$ServerViewModel(
    MotifServer profile,
    ServerAccessViewModel access,
    SessionCatalogViewModel sessions,
    DeviceRegistrationViewModel device,
    WorkspaceRegistryViewModel workspaces,
  ) : _profile = profile,
      _access = access,
      _sessions = sessions,
      _device = device,
      _workspaces = workspaces {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_profileKey, () => _profile);
      observationRegisterDebugProperty(_accessKey, () => _access);
      observationRegisterDebugProperty(_sessionsKey, () => _sessions);
      observationRegisterDebugProperty(_deviceKey, () => _device);
      observationRegisterDebugProperty(_workspacesKey, () => _workspaces);
    }
  }
  final ObservationKey<MotifServer> _profileKey = ObservationKey<MotifServer>(
    'ServerViewModel.profile',
  );
  MotifServer _profile;

  MotifServer get profile {
    observationAccess(_profileKey);
    return _profile;
  }

  set profile(MotifServer value) {
    if (_profile == value) return;
    observationMutation(_profileKey, () {
      _profile = value;
    });
  }

  final ObservationKey<ServerAccessViewModel> _accessKey =
      ObservationKey<ServerAccessViewModel>('ServerViewModel.access');
  final ServerAccessViewModel _access;

  ServerAccessViewModel get access {
    observationAccess(_accessKey);
    return _access;
  }

  final ObservationKey<SessionCatalogViewModel> _sessionsKey =
      ObservationKey<SessionCatalogViewModel>('ServerViewModel.sessions');
  final SessionCatalogViewModel _sessions;

  SessionCatalogViewModel get sessions {
    observationAccess(_sessionsKey);
    return _sessions;
  }

  final ObservationKey<DeviceRegistrationViewModel> _deviceKey =
      ObservationKey<DeviceRegistrationViewModel>('ServerViewModel.device');
  final DeviceRegistrationViewModel _device;

  DeviceRegistrationViewModel get device {
    observationAccess(_deviceKey);
    return _device;
  }

  final ObservationKey<WorkspaceRegistryViewModel> _workspacesKey =
      ObservationKey<WorkspaceRegistryViewModel>('ServerViewModel.workspaces');
  final WorkspaceRegistryViewModel _workspaces;

  WorkspaceRegistryViewModel get workspaces {
    observationAccess(_workspacesKey);
    return _workspaces;
  }
}

abstract class _$ServerRegistryViewModel with ObservableModelMixin {
  _$ServerRegistryViewModel(
    String? activeServerId,
    ObservableList<String> order,
    ObservableMap<String, ServerViewModel> entries,
  ) : _activeServerId = activeServerId,
      _order = order,
      _entries = entries {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(
        _activeServerIdKey,
        () => _activeServerId,
      );
      observationRegisterDebugProperty(_orderKey, () => _order);
      observationRegisterDebugProperty(_entriesKey, () => _entries);
    }
  }
  final ObservationKey<String?> _activeServerIdKey = ObservationKey<String?>(
    'ServerRegistryViewModel.activeServerId',
  );
  String? _activeServerId;

  String? get activeServerId {
    observationAccess(_activeServerIdKey);
    return _activeServerId;
  }

  set activeServerId(String? value) {
    if (_activeServerId == value) return;
    observationMutation(_activeServerIdKey, () {
      _activeServerId = value;
    });
  }

  final ObservationKey<ObservableList<String>> _orderKey =
      ObservationKey<ObservableList<String>>('ServerRegistryViewModel.order');
  final ObservableList<String> _order;

  ObservableList<String> get order {
    observationAccess(_orderKey);
    return _order;
  }

  final ObservationKey<ObservableMap<String, ServerViewModel>> _entriesKey =
      ObservationKey<ObservableMap<String, ServerViewModel>>(
        'ServerRegistryViewModel.entries',
      );
  final ObservableMap<String, ServerViewModel> _entries;

  ObservableMap<String, ServerViewModel> get entries {
    observationAccess(_entriesKey);
    return _entries;
  }
}
