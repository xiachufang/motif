// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$PreferencesViewModel with ObservableModelMixin {
  _$PreferencesViewModel(
    TerminalPreferencesViewModel terminal,
    QuickCommandViewModel quickCommands,
    PushPreferencesViewModel push,
  ) : _terminal = terminal,
      _quickCommands = quickCommands,
      _push = push {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_terminalKey, () => _terminal);
      observationRegisterDebugProperty(_quickCommandsKey, () => _quickCommands);
      observationRegisterDebugProperty(_pushKey, () => _push);
    }
  }
  final ObservationKey<TerminalPreferencesViewModel> _terminalKey =
      ObservationKey<TerminalPreferencesViewModel>(
        'PreferencesViewModel.terminal',
      );
  final TerminalPreferencesViewModel _terminal;

  TerminalPreferencesViewModel get terminal {
    observationAccess(_terminalKey);
    return _terminal;
  }

  final ObservationKey<QuickCommandViewModel> _quickCommandsKey =
      ObservationKey<QuickCommandViewModel>(
        'PreferencesViewModel.quickCommands',
      );
  final QuickCommandViewModel _quickCommands;

  QuickCommandViewModel get quickCommands {
    observationAccess(_quickCommandsKey);
    return _quickCommands;
  }

  final ObservationKey<PushPreferencesViewModel> _pushKey =
      ObservationKey<PushPreferencesViewModel>('PreferencesViewModel.push');
  final PushPreferencesViewModel _push;

  PushPreferencesViewModel get push {
    observationAccess(_pushKey);
    return _push;
  }
}

abstract class _$PlatformViewModel with ObservableModelMixin {
  _$PlatformViewModel(
    TailscaleViewModel tailscale,
    EmbeddedServerViewModel? embeddedServer,
  ) : _tailscale = tailscale,
      _embeddedServer = embeddedServer {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_tailscaleKey, () => _tailscale);
      observationRegisterDebugProperty(
        _embeddedServerKey,
        () => _embeddedServer,
      );
    }
  }
  final ObservationKey<TailscaleViewModel> _tailscaleKey =
      ObservationKey<TailscaleViewModel>('PlatformViewModel.tailscale');
  final TailscaleViewModel _tailscale;

  TailscaleViewModel get tailscale {
    observationAccess(_tailscaleKey);
    return _tailscale;
  }

  final ObservationKey<EmbeddedServerViewModel?> _embeddedServerKey =
      ObservationKey<EmbeddedServerViewModel?>(
        'PlatformViewModel.embeddedServer',
      );
  final EmbeddedServerViewModel? _embeddedServer;

  EmbeddedServerViewModel? get embeddedServer {
    observationAccess(_embeddedServerKey);
    return _embeddedServer;
  }
}

abstract class _$AppViewModel with ObservableModelMixin {
  _$AppViewModel(
    AppShellViewModel shell,
    PreferencesViewModel preferences,
    PlatformViewModel platform,
    ServerRegistryViewModel servers,
  ) : _shell = shell,
      _preferences = preferences,
      _platform = platform,
      _servers = servers {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_shellKey, () => _shell);
      observationRegisterDebugProperty(_preferencesKey, () => _preferences);
      observationRegisterDebugProperty(_platformKey, () => _platform);
      observationRegisterDebugProperty(_serversKey, () => _servers);
    }
  }
  final ObservationKey<AppShellViewModel> _shellKey =
      ObservationKey<AppShellViewModel>('AppViewModel.shell');
  final AppShellViewModel _shell;

  AppShellViewModel get shell {
    observationAccess(_shellKey);
    return _shell;
  }

  final ObservationKey<PreferencesViewModel> _preferencesKey =
      ObservationKey<PreferencesViewModel>('AppViewModel.preferences');
  final PreferencesViewModel _preferences;

  PreferencesViewModel get preferences {
    observationAccess(_preferencesKey);
    return _preferences;
  }

  final ObservationKey<PlatformViewModel> _platformKey =
      ObservationKey<PlatformViewModel>('AppViewModel.platform');
  final PlatformViewModel _platform;

  PlatformViewModel get platform {
    observationAccess(_platformKey);
    return _platform;
  }

  final ObservationKey<ServerRegistryViewModel> _serversKey =
      ObservationKey<ServerRegistryViewModel>('AppViewModel.servers');
  final ServerRegistryViewModel _servers;

  ServerRegistryViewModel get servers {
    observationAccess(_serversKey);
    return _servers;
  }
}
