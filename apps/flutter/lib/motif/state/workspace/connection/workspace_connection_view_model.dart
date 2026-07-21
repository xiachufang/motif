import 'package:flutter_observation/flutter_observation.dart';

import '../../connection/connection_state.dart';
import '../workspace_runtime_state.dart';
import 'workspace_attachment_runtime.dart';

part 'workspace_connection_view_model.g.dart';

enum WorkspaceConnectionPhase {
  disconnected,
  connecting,
  ready,
  attaching,
  attached,
  reconnecting,
  suspended,
  failed,
}

sealed class WorkspaceConnectionStatus {
  const WorkspaceConnectionStatus();
}

class ConnDisconnected extends WorkspaceConnectionStatus {
  const ConnDisconnected();
}

class ConnConnecting extends WorkspaceConnectionStatus {
  const ConnConnecting();
}

class ConnConnected extends WorkspaceConnectionStatus {
  const ConnConnected();
}

class ConnAttached extends WorkspaceConnectionStatus {
  const ConnAttached(this.session);

  final String session;
}

class ConnFailed extends WorkspaceConnectionStatus {
  const ConnFailed(this.message);

  final String message;
}

class ConnSuspended extends WorkspaceConnectionStatus {
  const ConnSuspended(this.message, {this.session});

  final String message;
  final String? session;
}

/// Observable connection projection for one retained workspace.
@ObservableModel()
class WorkspaceConnectionViewModel extends _$WorkspaceConnectionViewModel {
  WorkspaceConnectionViewModel({
    WorkspaceRuntimeState runtime = const WorkspaceRuntimeState.initial(),
    WorkspaceAttachmentRuntimeState attachment =
        const WorkspaceAttachmentDetached(),
    WorkspaceConnectionPhase phase = WorkspaceConnectionPhase.disconnected,
    bool desiredConnected = false,
    bool transportAvailable = false,
    int reconnectAttempt = 0,
    String? message,
    ConnectionBlocker? blocker,
    String? attachedSession,
  }) : super(
         runtime,
         attachment,
         phase,
         desiredConnected,
         transportAvailable,
         reconnectAttempt,
         message,
         blocker,
         attachedSession,
       );

  bool get isAttached => phase == WorkspaceConnectionPhase.attached;

  bool get canInput => isAttached && transportAvailable;

  WorkspaceConnectionStatus get status => switch (phase) {
    WorkspaceConnectionPhase.disconnected => const ConnDisconnected(),
    WorkspaceConnectionPhase.connecting ||
    WorkspaceConnectionPhase.attaching ||
    WorkspaceConnectionPhase.reconnecting => const ConnConnecting(),
    WorkspaceConnectionPhase.ready => const ConnConnected(),
    WorkspaceConnectionPhase.attached => ConnAttached(attachedSession ?? ''),
    WorkspaceConnectionPhase.suspended => ConnSuspended(
      message ?? 'connection suspended',
      session: attachedSession,
    ),
    WorkspaceConnectionPhase.failed => ConnFailed(
      message ?? 'connection failed',
    ),
  };

  void applyStatus(WorkspaceConnectionStatus status, {bool? live}) {
    observationTransaction(() {
      switch (status) {
        case ConnDisconnected():
          phase = WorkspaceConnectionPhase.disconnected;
          attachedSession = null;
          message = null;
          blocker = null;
        case ConnConnecting():
          phase = WorkspaceConnectionPhase.connecting;
          message = null;
          blocker = null;
        case ConnConnected():
          phase = WorkspaceConnectionPhase.ready;
          attachedSession = null;
          message = null;
          blocker = null;
        case ConnAttached(:final session):
          phase = WorkspaceConnectionPhase.attached;
          attachedSession = session;
          message = null;
          blocker = null;
        case ConnFailed(:final message):
          phase = WorkspaceConnectionPhase.failed;
          this.message = message;
          blocker = null;
        case ConnSuspended(:final message, :final session):
          phase = WorkspaceConnectionPhase.suspended;
          attachedSession = session;
          this.message = message;
      }
      if (live != null) transportAvailable = live;
    });
  }
}
