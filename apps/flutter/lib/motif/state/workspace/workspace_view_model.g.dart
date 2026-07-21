// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'workspace_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$WorkspaceViewModel with ObservableModelMixin {
  _$WorkspaceViewModel(
    String serverId,
    String session,
    WorkspaceConnectionViewModel connection,
    TerminalViewModel terminal,
    ViewTabsViewModel views,
    RemotePortsViewModel remotePorts,
    WorkspaceContentViewModel content,
    WorkspacePresenceViewModel presence,
  ) : _serverId = serverId,
      _session = session,
      _connection = connection,
      _terminal = terminal,
      _views = views,
      _remotePorts = remotePorts,
      _content = content,
      _presence = presence {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_serverIdKey, () => _serverId);
      observationRegisterDebugProperty(_sessionKey, () => _session);
      observationRegisterDebugProperty(_connectionKey, () => _connection);
      observationRegisterDebugProperty(_terminalKey, () => _terminal);
      observationRegisterDebugProperty(_viewsKey, () => _views);
      observationRegisterDebugProperty(_remotePortsKey, () => _remotePorts);
      observationRegisterDebugProperty(_contentKey, () => _content);
      observationRegisterDebugProperty(_presenceKey, () => _presence);
    }
  }
  final ObservationKey<String> _serverIdKey = ObservationKey<String>(
    'WorkspaceViewModel.serverId',
  );
  final String _serverId;

  String get serverId {
    observationAccess(_serverIdKey);
    return _serverId;
  }

  final ObservationKey<String> _sessionKey = ObservationKey<String>(
    'WorkspaceViewModel.session',
  );
  final String _session;

  String get session {
    observationAccess(_sessionKey);
    return _session;
  }

  final ObservationKey<WorkspaceConnectionViewModel> _connectionKey =
      ObservationKey<WorkspaceConnectionViewModel>(
        'WorkspaceViewModel.connection',
      );
  final WorkspaceConnectionViewModel _connection;

  WorkspaceConnectionViewModel get connection {
    observationAccess(_connectionKey);
    return _connection;
  }

  final ObservationKey<TerminalViewModel> _terminalKey =
      ObservationKey<TerminalViewModel>('WorkspaceViewModel.terminal');
  final TerminalViewModel _terminal;

  TerminalViewModel get terminal {
    observationAccess(_terminalKey);
    return _terminal;
  }

  final ObservationKey<ViewTabsViewModel> _viewsKey =
      ObservationKey<ViewTabsViewModel>('WorkspaceViewModel.views');
  final ViewTabsViewModel _views;

  ViewTabsViewModel get views {
    observationAccess(_viewsKey);
    return _views;
  }

  final ObservationKey<RemotePortsViewModel> _remotePortsKey =
      ObservationKey<RemotePortsViewModel>('WorkspaceViewModel.remotePorts');
  final RemotePortsViewModel _remotePorts;

  RemotePortsViewModel get remotePorts {
    observationAccess(_remotePortsKey);
    return _remotePorts;
  }

  final ObservationKey<WorkspaceContentViewModel> _contentKey =
      ObservationKey<WorkspaceContentViewModel>('WorkspaceViewModel.content');
  final WorkspaceContentViewModel _content;

  WorkspaceContentViewModel get content {
    observationAccess(_contentKey);
    return _content;
  }

  final ObservationKey<WorkspacePresenceViewModel> _presenceKey =
      ObservationKey<WorkspacePresenceViewModel>('WorkspaceViewModel.presence');
  final WorkspacePresenceViewModel _presence;

  WorkspacePresenceViewModel get presence {
    observationAccess(_presenceKey);
    return _presence;
  }
}
