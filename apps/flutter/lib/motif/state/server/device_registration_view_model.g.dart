// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_registration_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$DeviceRegistrationViewModel with ObservableModelMixin {
  _$DeviceRegistrationViewModel(
    DeviceRegistrationPhase phase,
    String? instanceId,
    String? error,
  ) : _phase = phase,
      _instanceId = instanceId,
      _error = error {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_phaseKey, () => _phase);
      observationRegisterDebugProperty(_instanceIdKey, () => _instanceId);
      observationRegisterDebugProperty(_errorKey, () => _error);
    }
  }
  final ObservationKey<DeviceRegistrationPhase> _phaseKey =
      ObservationKey<DeviceRegistrationPhase>(
        'DeviceRegistrationViewModel.phase',
      );
  DeviceRegistrationPhase _phase;

  DeviceRegistrationPhase get phase {
    observationAccess(_phaseKey);
    return _phase;
  }

  set phase(DeviceRegistrationPhase value) {
    if (_phase == value) return;
    observationMutation(_phaseKey, () {
      _phase = value;
    });
  }

  final ObservationKey<String?> _instanceIdKey = ObservationKey<String?>(
    'DeviceRegistrationViewModel.instanceId',
  );
  String? _instanceId;

  String? get instanceId {
    observationAccess(_instanceIdKey);
    return _instanceId;
  }

  set instanceId(String? value) {
    if (_instanceId == value) return;
    observationMutation(_instanceIdKey, () {
      _instanceId = value;
    });
  }

  final ObservationKey<String?> _errorKey = ObservationKey<String?>(
    'DeviceRegistrationViewModel.error',
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
}
