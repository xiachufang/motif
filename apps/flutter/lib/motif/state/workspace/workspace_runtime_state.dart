import '../connection/connection_state.dart';

/// Focus/lifecycle is orthogonal to the workspace transport state.
sealed class WorkspaceActivityState {
  const WorkspaceActivityState();
}

final class WorkspaceActivityForeground extends WorkspaceActivityState {
  const WorkspaceActivityForeground();
}

final class WorkspaceActivityBackground extends WorkspaceActivityState {
  const WorkspaceActivityBackground();
}

final class WorkspaceActivityPaused extends WorkspaceActivityState {
  const WorkspaceActivityPaused();
}

sealed class WorkspaceLinkState {
  const WorkspaceLinkState();

  bool get wantsConnection;
}

final class WorkspaceLinkDisconnected extends WorkspaceLinkState {
  const WorkspaceLinkDisconnected();

  @override
  bool get wantsConnection => false;
}

final class WorkspaceLinkDisconnecting extends WorkspaceLinkState {
  const WorkspaceLinkDisconnecting();

  @override
  bool get wantsConnection => false;
}

sealed class WorkspaceLinkDesiredConnected extends WorkspaceLinkState {
  const WorkspaceLinkDesiredConnected();

  @override
  bool get wantsConnection => true;
}

sealed class WorkspaceLinkSynchronizing extends WorkspaceLinkDesiredConnected {
  const WorkspaceLinkSynchronizing({
    required this.attempt,
    required this.reconnect,
    this.session,
  });

  final int attempt;
  final bool reconnect;
  final String? session;
}

final class WorkspaceLinkResolving extends WorkspaceLinkSynchronizing {
  const WorkspaceLinkResolving({
    required super.attempt,
    required super.reconnect,
    super.session,
    required this.force,
    this.promotion = false,
  });

  final bool force;
  final bool promotion;
}

final class WorkspaceLinkEstablishing extends WorkspaceLinkSynchronizing {
  const WorkspaceLinkEstablishing({
    required super.attempt,
    required super.reconnect,
    super.session,
    required this.force,
    required this.promotion,
  });

  final bool force;
  final bool promotion;
}

sealed class WorkspaceLinkOnline extends WorkspaceLinkDesiredConnected {
  const WorkspaceLinkOnline();
}

final class WorkspaceLinkReady extends WorkspaceLinkOnline {
  const WorkspaceLinkReady();
}

final class WorkspaceLinkAttached extends WorkspaceLinkOnline {
  const WorkspaceLinkAttached(this.session);

  final String session;
}

final class WorkspaceLinkRecovering extends WorkspaceLinkDesiredConnected {
  const WorkspaceLinkRecovering({
    required this.attempt,
    required this.error,
    required this.delay,
    this.session,
  });

  final int attempt;
  final Object error;
  final Duration delay;
  final String? session;
}

final class WorkspaceLinkBlocked extends WorkspaceLinkDesiredConnected {
  const WorkspaceLinkBlocked({required this.blocker, this.session});

  final ConnectionBlocker blocker;
  final String? session;
}

/// Authoritative control state for one exact `(serverId, session)` node.
///
/// [activity] and [link] are parallel regions: a retained background workspace
/// can stay attached, while a paused mobile workspace retains its link state
/// with all control effects invalidated.
final class WorkspaceRuntimeState {
  const WorkspaceRuntimeState({
    required this.generation,
    required this.activity,
    required this.link,
  });

  const WorkspaceRuntimeState.initial()
    : generation = 0,
      activity = const WorkspaceActivityForeground(),
      link = const WorkspaceLinkDisconnected();

  final int generation;
  final WorkspaceActivityState activity;
  final WorkspaceLinkState link;

  bool get wantsConnection => link.wantsConnection;
  bool get isOnline => link is WorkspaceLinkOnline;

  WorkspaceRuntimeState copyWith({
    int? generation,
    WorkspaceActivityState? activity,
    WorkspaceLinkState? link,
  }) => WorkspaceRuntimeState(
    generation: generation ?? this.generation,
    activity: activity ?? this.activity,
    link: link ?? this.link,
  );
}
