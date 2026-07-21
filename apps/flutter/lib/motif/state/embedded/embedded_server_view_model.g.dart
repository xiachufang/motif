// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'embedded_server_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$EmbeddedServerViewModel with ObservableModelMixin {
  _$EmbeddedServerViewModel(
    bool available,
    EmbeddedServerConfig config,
    EmbeddedServerStatus status,
  ) : _available = available,
      _config = config,
      _status = status {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_availableKey, () => _available);
      observationRegisterDebugProperty(_configKey, () => _config);
      observationRegisterDebugProperty(_statusKey, () => _status);
    }
  }
  final ObservationKey<bool> _availableKey = ObservationKey<bool>(
    'EmbeddedServerViewModel.available',
  );
  bool _available;

  bool get available {
    observationAccess(_availableKey);
    return _available;
  }

  set available(bool value) {
    if (_available == value) return;
    observationMutation(_availableKey, () {
      _available = value;
    });
  }

  final ObservationKey<EmbeddedServerConfig> _configKey =
      ObservationKey<EmbeddedServerConfig>('EmbeddedServerViewModel.config');
  EmbeddedServerConfig _config;

  EmbeddedServerConfig get config {
    observationAccess(_configKey);
    return _config;
  }

  set config(EmbeddedServerConfig value) {
    if (_config == value) return;
    observationMutation(_configKey, () {
      _config = value;
    });
  }

  final ObservationKey<EmbeddedServerStatus> _statusKey =
      ObservationKey<EmbeddedServerStatus>('EmbeddedServerViewModel.status');
  EmbeddedServerStatus _status;

  EmbeddedServerStatus get status {
    observationAccess(_statusKey);
    return _status;
  }

  set status(EmbeddedServerStatus value) {
    if (_status == value) return;
    observationMutation(_statusKey, () {
      _status = value;
    });
  }
}
