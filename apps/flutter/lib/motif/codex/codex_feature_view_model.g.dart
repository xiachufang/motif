// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'codex_feature_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$CodexFeatureViewModel with ObservableModelMixin {
  _$CodexFeatureViewModel(
    CodexServiceState? service,
    String? setupError,
    bool operationInFlight,
    bool sideChatOpening,
  ) : _service = service,
      _setupError = setupError,
      _operationInFlight = operationInFlight,
      _sideChatOpening = sideChatOpening {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_serviceKey, () => _service);
      observationRegisterDebugProperty(_setupErrorKey, () => _setupError);
      observationRegisterDebugProperty(
        _operationInFlightKey,
        () => _operationInFlight,
      );
      observationRegisterDebugProperty(
        _sideChatOpeningKey,
        () => _sideChatOpening,
      );
    }
  }
  final ObservationKey<CodexServiceState?> _serviceKey =
      ObservationKey<CodexServiceState?>('CodexFeatureViewModel.service');
  CodexServiceState? _service;

  CodexServiceState? get service {
    observationAccess(_serviceKey);
    return _service;
  }

  set service(CodexServiceState? value) {
    if (_service == value) return;
    observationMutation(_serviceKey, () {
      _service = value;
    });
  }

  final ObservationKey<String?> _setupErrorKey = ObservationKey<String?>(
    'CodexFeatureViewModel.setupError',
  );
  String? _setupError;

  String? get setupError {
    observationAccess(_setupErrorKey);
    return _setupError;
  }

  set setupError(String? value) {
    if (_setupError == value) return;
    observationMutation(_setupErrorKey, () {
      _setupError = value;
    });
  }

  final ObservationKey<bool> _operationInFlightKey = ObservationKey<bool>(
    'CodexFeatureViewModel.operationInFlight',
  );
  bool _operationInFlight;

  bool get operationInFlight {
    observationAccess(_operationInFlightKey);
    return _operationInFlight;
  }

  set operationInFlight(bool value) {
    if (_operationInFlight == value) return;
    observationMutation(_operationInFlightKey, () {
      _operationInFlight = value;
    });
  }

  final ObservationKey<bool> _sideChatOpeningKey = ObservationKey<bool>(
    'CodexFeatureViewModel.sideChatOpening',
  );
  bool _sideChatOpening;

  bool get sideChatOpening {
    observationAccess(_sideChatOpeningKey);
    return _sideChatOpening;
  }

  set sideChatOpening(bool value) {
    if (_sideChatOpening == value) return;
    observationMutation(_sideChatOpeningKey, () {
      _sideChatOpening = value;
    });
  }
}
