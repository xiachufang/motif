// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'store_view_models.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$PushPreferencesViewModel with ObservableModelMixin {
  _$PushPreferencesViewModel(
    PushRuntimeState runtime,
    bool enabled,
    ObservableSet<String> mutedSessions,
  ) : _runtime = runtime,
      _enabled = enabled,
      _mutedSessions = mutedSessions {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_runtimeKey, () => _runtime);
      observationRegisterDebugProperty(_enabledKey, () => _enabled);
      observationRegisterDebugProperty(_mutedSessionsKey, () => _mutedSessions);
    }
  }
  final ObservationKey<PushRuntimeState> _runtimeKey =
      ObservationKey<PushRuntimeState>('PushPreferencesViewModel.runtime');
  PushRuntimeState _runtime;

  PushRuntimeState get runtime {
    observationAccess(_runtimeKey);
    return _runtime;
  }

  set runtime(PushRuntimeState value) {
    if (_runtime == value) return;
    observationMutation(_runtimeKey, () {
      _runtime = value;
    });
  }

  final ObservationKey<bool> _enabledKey = ObservationKey<bool>(
    'PushPreferencesViewModel.enabled',
  );
  bool _enabled;

  bool get enabled {
    observationAccess(_enabledKey);
    return _enabled;
  }

  set enabled(bool value) {
    if (_enabled == value) return;
    observationMutation(_enabledKey, () {
      _enabled = value;
    });
  }

  final ObservationKey<ObservableSet<String>> _mutedSessionsKey =
      ObservationKey<ObservableSet<String>>(
        'PushPreferencesViewModel.mutedSessions',
      );
  final ObservableSet<String> _mutedSessions;

  ObservableSet<String> get mutedSessions {
    observationAccess(_mutedSessionsKey);
    return _mutedSessions;
  }
}

abstract class _$ServerProfilesViewModel with ObservableModelMixin {
  _$ServerProfilesViewModel(
    ObservableList<MotifServer> servers,
    String? activeId,
  ) : _servers = servers,
      _activeId = activeId {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_serversKey, () => _servers);
      observationRegisterDebugProperty(_activeIdKey, () => _activeId);
    }
  }
  final ObservationKey<ObservableList<MotifServer>> _serversKey =
      ObservationKey<ObservableList<MotifServer>>(
        'ServerProfilesViewModel.servers',
      );
  final ObservableList<MotifServer> _servers;

  ObservableList<MotifServer> get servers {
    observationAccess(_serversKey);
    return _servers;
  }

  final ObservationKey<String?> _activeIdKey = ObservationKey<String?>(
    'ServerProfilesViewModel.activeId',
  );
  String? _activeId;

  String? get activeId {
    observationAccess(_activeIdKey);
    return _activeId;
  }

  set activeId(String? value) {
    if (_activeId == value) return;
    observationMutation(_activeIdKey, () {
      _activeId = value;
    });
  }
}

abstract class _$TerminalPreferencesViewModel with ObservableModelMixin {
  _$TerminalPreferencesViewModel(TerminalSettings settings)
    : _settings = settings {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_settingsKey, () => _settings);
    }
  }
  final ObservationKey<TerminalSettings> _settingsKey =
      ObservationKey<TerminalSettings>('TerminalPreferencesViewModel.settings');
  TerminalSettings _settings;

  TerminalSettings get settings {
    observationAccess(_settingsKey);
    return _settings;
  }

  set settings(TerminalSettings value) {
    if (_settings == value) return;
    observationMutation(_settingsKey, () {
      _settings = value;
    });
  }
}

abstract class _$QuickCommandViewModel with ObservableModelMixin {
  _$QuickCommandViewModel(
    ObservableList<QuickCommand> commands,
    ObservableList<QuickCommandSet> sets,
  ) : _commands = commands,
      _sets = sets {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_commandsKey, () => _commands);
      observationRegisterDebugProperty(_setsKey, () => _sets);
    }
  }
  final ObservationKey<ObservableList<QuickCommand>> _commandsKey =
      ObservationKey<ObservableList<QuickCommand>>(
        'QuickCommandViewModel.commands',
      );
  final ObservableList<QuickCommand> _commands;

  ObservableList<QuickCommand> get commands {
    observationAccess(_commandsKey);
    return _commands;
  }

  final ObservationKey<ObservableList<QuickCommandSet>> _setsKey =
      ObservationKey<ObservableList<QuickCommandSet>>(
        'QuickCommandViewModel.sets',
      );
  final ObservableList<QuickCommandSet> _sets;

  ObservableList<QuickCommandSet> get sets {
    observationAccess(_setsKey);
    return _sets;
  }
}
