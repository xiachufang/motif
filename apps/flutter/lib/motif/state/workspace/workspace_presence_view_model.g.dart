// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'workspace_presence_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$WorkspacePresenceViewModel with ObservableModelMixin {
  _$WorkspacePresenceViewModel(
    ObservableList<ClientInfo> clients,
    String? sessionTheme,
    MotifNotification? latestNotification,
  ) : _clients = clients,
      _sessionTheme = sessionTheme,
      _latestNotification = latestNotification {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_clientsKey, () => _clients);
      observationRegisterDebugProperty(_sessionThemeKey, () => _sessionTheme);
      observationRegisterDebugProperty(
        _latestNotificationKey,
        () => _latestNotification,
      );
    }
  }
  final ObservationKey<ObservableList<ClientInfo>> _clientsKey =
      ObservationKey<ObservableList<ClientInfo>>(
        'WorkspacePresenceViewModel.clients',
      );
  final ObservableList<ClientInfo> _clients;

  ObservableList<ClientInfo> get clients {
    observationAccess(_clientsKey);
    return _clients;
  }

  final ObservationKey<String?> _sessionThemeKey = ObservationKey<String?>(
    'WorkspacePresenceViewModel.sessionTheme',
  );
  String? _sessionTheme;

  String? get sessionTheme {
    observationAccess(_sessionThemeKey);
    return _sessionTheme;
  }

  set sessionTheme(String? value) {
    if (_sessionTheme == value) return;
    observationMutation(_sessionThemeKey, () {
      _sessionTheme = value;
    });
  }

  final ObservationKey<MotifNotification?> _latestNotificationKey =
      ObservationKey<MotifNotification?>(
        'WorkspacePresenceViewModel.latestNotification',
      );
  MotifNotification? _latestNotification;

  MotifNotification? get latestNotification {
    observationAccess(_latestNotificationKey);
    return _latestNotification;
  }

  set latestNotification(MotifNotification? value) {
    if (_latestNotification == value) return;
    observationMutation(_latestNotificationKey, () {
      _latestNotification = value;
    });
  }
}
