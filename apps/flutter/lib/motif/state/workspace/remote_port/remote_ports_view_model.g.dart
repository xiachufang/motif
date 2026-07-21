// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'remote_ports_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$RemotePortsViewModel with ObservableModelMixin {
  _$RemotePortsViewModel(
    RemotePortsPhase phase,
    ObservableList<RemotePortMapping> mappings,
    String? error,
  ) : _phase = phase,
      _mappings = mappings,
      _error = error {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_phaseKey, () => _phase);
      observationRegisterDebugProperty(_mappingsKey, () => _mappings);
      observationRegisterDebugProperty(_errorKey, () => _error);
    }
  }
  final ObservationKey<RemotePortsPhase> _phaseKey =
      ObservationKey<RemotePortsPhase>('RemotePortsViewModel.phase');
  RemotePortsPhase _phase;

  RemotePortsPhase get phase {
    observationAccess(_phaseKey);
    return _phase;
  }

  set phase(RemotePortsPhase value) {
    if (_phase == value) return;
    observationMutation(_phaseKey, () {
      _phase = value;
    });
  }

  final ObservationKey<ObservableList<RemotePortMapping>> _mappingsKey =
      ObservationKey<ObservableList<RemotePortMapping>>(
        'RemotePortsViewModel.mappings',
      );
  final ObservableList<RemotePortMapping> _mappings;

  ObservableList<RemotePortMapping> get mappings {
    observationAccess(_mappingsKey);
    return _mappings;
  }

  final ObservationKey<String?> _errorKey = ObservationKey<String?>(
    'RemotePortsViewModel.error',
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
