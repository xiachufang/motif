// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'workspace_connection_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$WorkspaceConnectionViewModel with ObservableModelMixin {
  _$WorkspaceConnectionViewModel(
    WorkspaceRuntimeState runtime,
    WorkspaceAttachmentRuntimeState attachment,
    WorkspaceConnectionPhase phase,
    bool desiredConnected,
    bool transportAvailable,
    int reconnectAttempt,
    String? message,
    ConnectionBlocker? blocker,
    String? attachedSession,
  ) : _runtime = runtime,
      _attachment = attachment,
      _phase = phase,
      _desiredConnected = desiredConnected,
      _transportAvailable = transportAvailable,
      _reconnectAttempt = reconnectAttempt,
      _message = message,
      _blocker = blocker,
      _attachedSession = attachedSession {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_runtimeKey, () => _runtime);
      observationRegisterDebugProperty(_attachmentKey, () => _attachment);
      observationRegisterDebugProperty(_phaseKey, () => _phase);
      observationRegisterDebugProperty(
        _desiredConnectedKey,
        () => _desiredConnected,
      );
      observationRegisterDebugProperty(
        _transportAvailableKey,
        () => _transportAvailable,
      );
      observationRegisterDebugProperty(
        _reconnectAttemptKey,
        () => _reconnectAttempt,
      );
      observationRegisterDebugProperty(_messageKey, () => _message);
      observationRegisterDebugProperty(_blockerKey, () => _blocker);
      observationRegisterDebugProperty(
        _attachedSessionKey,
        () => _attachedSession,
      );
    }
  }
  final ObservationKey<WorkspaceRuntimeState> _runtimeKey =
      ObservationKey<WorkspaceRuntimeState>(
        'WorkspaceConnectionViewModel.runtime',
      );
  WorkspaceRuntimeState _runtime;

  WorkspaceRuntimeState get runtime {
    observationAccess(_runtimeKey);
    return _runtime;
  }

  set runtime(WorkspaceRuntimeState value) {
    if (_runtime == value) return;
    observationMutation(_runtimeKey, () {
      _runtime = value;
    });
  }

  final ObservationKey<WorkspaceAttachmentRuntimeState> _attachmentKey =
      ObservationKey<WorkspaceAttachmentRuntimeState>(
        'WorkspaceConnectionViewModel.attachment',
      );
  WorkspaceAttachmentRuntimeState _attachment;

  WorkspaceAttachmentRuntimeState get attachment {
    observationAccess(_attachmentKey);
    return _attachment;
  }

  set attachment(WorkspaceAttachmentRuntimeState value) {
    if (_attachment == value) return;
    observationMutation(_attachmentKey, () {
      _attachment = value;
    });
  }

  final ObservationKey<WorkspaceConnectionPhase> _phaseKey =
      ObservationKey<WorkspaceConnectionPhase>(
        'WorkspaceConnectionViewModel.phase',
      );
  WorkspaceConnectionPhase _phase;

  WorkspaceConnectionPhase get phase {
    observationAccess(_phaseKey);
    return _phase;
  }

  set phase(WorkspaceConnectionPhase value) {
    if (_phase == value) return;
    observationMutation(_phaseKey, () {
      _phase = value;
    });
  }

  final ObservationKey<bool> _desiredConnectedKey = ObservationKey<bool>(
    'WorkspaceConnectionViewModel.desiredConnected',
  );
  bool _desiredConnected;

  bool get desiredConnected {
    observationAccess(_desiredConnectedKey);
    return _desiredConnected;
  }

  set desiredConnected(bool value) {
    if (_desiredConnected == value) return;
    observationMutation(_desiredConnectedKey, () {
      _desiredConnected = value;
    });
  }

  final ObservationKey<bool> _transportAvailableKey = ObservationKey<bool>(
    'WorkspaceConnectionViewModel.transportAvailable',
  );
  bool _transportAvailable;

  bool get transportAvailable {
    observationAccess(_transportAvailableKey);
    return _transportAvailable;
  }

  set transportAvailable(bool value) {
    if (_transportAvailable == value) return;
    observationMutation(_transportAvailableKey, () {
      _transportAvailable = value;
    });
  }

  final ObservationKey<int> _reconnectAttemptKey = ObservationKey<int>(
    'WorkspaceConnectionViewModel.reconnectAttempt',
  );
  int _reconnectAttempt;

  int get reconnectAttempt {
    observationAccess(_reconnectAttemptKey);
    return _reconnectAttempt;
  }

  set reconnectAttempt(int value) {
    if (_reconnectAttempt == value) return;
    observationMutation(_reconnectAttemptKey, () {
      _reconnectAttempt = value;
    });
  }

  final ObservationKey<String?> _messageKey = ObservationKey<String?>(
    'WorkspaceConnectionViewModel.message',
  );
  String? _message;

  String? get message {
    observationAccess(_messageKey);
    return _message;
  }

  set message(String? value) {
    if (_message == value) return;
    observationMutation(_messageKey, () {
      _message = value;
    });
  }

  final ObservationKey<ConnectionBlocker?> _blockerKey =
      ObservationKey<ConnectionBlocker?>(
        'WorkspaceConnectionViewModel.blocker',
      );
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

  final ObservationKey<String?> _attachedSessionKey = ObservationKey<String?>(
    'WorkspaceConnectionViewModel.attachedSession',
  );
  String? _attachedSession;

  String? get attachedSession {
    observationAccess(_attachedSessionKey);
    return _attachedSession;
  }

  set attachedSession(String? value) {
    if (_attachedSession == value) return;
    observationMutation(_attachedSessionKey, () {
      _attachedSession = value;
    });
  }
}
