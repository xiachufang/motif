import '../../models/settings.dart';
import '../connection/connection_state.dart';

sealed class ServerRuntimeState {
  const ServerRuntimeState();

  int get generation;
  bool get wantsConnection;
}

final class ServerRuntimeDisconnected extends ServerRuntimeState {
  const ServerRuntimeDisconnected({this.generation = 0});

  @override
  final int generation;

  @override
  bool get wantsConnection => false;
}

final class ServerRuntimeDisconnecting extends ServerRuntimeState {
  const ServerRuntimeDisconnecting({required this.generation});

  @override
  final int generation;

  @override
  bool get wantsConnection => false;
}

sealed class ServerRuntimeDesiredConnected extends ServerRuntimeState {
  const ServerRuntimeDesiredConnected({required this.generation});

  @override
  final int generation;

  @override
  bool get wantsConnection => true;
}

sealed class ServerRuntimeSynchronizing extends ServerRuntimeDesiredConnected {
  const ServerRuntimeSynchronizing({
    required super.generation,
    required this.attempt,
    required this.reconnect,
  });

  final int attempt;
  final bool reconnect;
}

final class ServerRuntimeResolving extends ServerRuntimeSynchronizing {
  const ServerRuntimeResolving({
    required super.generation,
    required super.attempt,
    required super.reconnect,
    required this.force,
    this.promotion = false,
  });

  final bool force;
  final bool promotion;
}

final class ServerRuntimeEstablishing extends ServerRuntimeSynchronizing {
  const ServerRuntimeEstablishing({
    required super.generation,
    required super.attempt,
    required super.reconnect,
    required this.target,
    required this.force,
    required this.promotion,
  });

  final MotifServer target;
  final bool force;
  final bool promotion;
}

final class ServerRuntimePromotingRoute extends ServerRuntimeSynchronizing {
  const ServerRuntimePromotingRoute({
    required super.generation,
    required super.attempt,
    required super.reconnect,
  });
}

final class ServerRuntimeLoadingCatalog extends ServerRuntimeSynchronizing {
  const ServerRuntimeLoadingCatalog({
    required super.generation,
    required super.attempt,
    required super.reconnect,
  });
}

sealed class ServerRuntimeOnline extends ServerRuntimeDesiredConnected {
  const ServerRuntimeOnline({required super.generation});
}

final class ServerRuntimeReady extends ServerRuntimeOnline {
  const ServerRuntimeReady({
    required super.generation,
    required this.catalogUpdatedAt,
  });

  final DateTime catalogUpdatedAt;
}

final class ServerRuntimeRefreshing extends ServerRuntimeOnline {
  const ServerRuntimeRefreshing({
    required super.generation,
    required this.previousUpdatedAt,
  });

  final DateTime? previousUpdatedAt;
}

final class ServerRuntimeDegraded extends ServerRuntimeOnline {
  const ServerRuntimeDegraded({
    required super.generation,
    required this.error,
    required this.previousUpdatedAt,
  });

  final Object error;
  final DateTime? previousUpdatedAt;
}

final class ServerRuntimeRecovering extends ServerRuntimeDesiredConnected {
  const ServerRuntimeRecovering({
    required super.generation,
    required this.attempt,
    required this.error,
    required this.delay,
  });

  final int attempt;
  final Object error;
  final Duration delay;
}

final class ServerRuntimeBlocked extends ServerRuntimeDesiredConnected {
  const ServerRuntimeBlocked({
    required super.generation,
    required this.blocker,
  });

  final ConnectionBlocker blocker;
}

/// App lifecycle is an ancestor state. The child state is retained for UI
/// projection, but its effects have been invalidated.
final class ServerRuntimePaused extends ServerRuntimeState {
  const ServerRuntimePaused(this.previous);

  final ServerRuntimeState previous;

  @override
  int get generation => previous.generation;

  @override
  bool get wantsConnection => previous.wantsConnection;
}

extension ServerRuntimeStateProjection on ServerRuntimeState {
  ServerRuntimeState get visibleState => switch (this) {
    ServerRuntimePaused(:final previous) => previous.visibleState,
    _ => this,
  };

  bool get isOnline => visibleState is ServerRuntimeOnline;
}
