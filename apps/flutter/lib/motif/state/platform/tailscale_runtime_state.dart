import 'tailscale_models.dart';

sealed class TailscaleLifecycleState {
  const TailscaleLifecycleState();

  TailscaleState get visibleState;
}

final class TailscaleLifecycleStopped extends TailscaleLifecycleState {
  const TailscaleLifecycleStopped();

  @override
  TailscaleState get visibleState => TailscaleState.stopped;
}

/// A native node is being brought up. [visibleState] also carries transient
/// backend detail such as "waiting for login URL".
final class TailscaleLifecycleStarting extends TailscaleLifecycleState {
  const TailscaleLifecycleStarting(this.visibleState);

  @override
  final TailscaleState visibleState;
}

final class TailscaleLifecycleNeedsAuth extends TailscaleLifecycleState {
  const TailscaleLifecycleNeedsAuth(
    this.visibleState, {
    required this.operationPending,
  });

  @override
  final TailscaleState visibleState;

  /// True while the original `tailscale_up` operation is still waiting for
  /// the browser login, false when a later health probe reported auth loss.
  final bool operationPending;
}

final class TailscaleLifecycleRunning extends TailscaleLifecycleState {
  const TailscaleLifecycleRunning();

  @override
  TailscaleState get visibleState =>
      const TailscaleState(TailscaleStatus.running);
}

final class TailscaleLifecycleDegraded extends TailscaleLifecycleState {
  const TailscaleLifecycleDegraded(this.visibleState);

  @override
  final TailscaleState visibleState;
}

final class TailscaleLifecycleRestarting extends TailscaleLifecycleState {
  const TailscaleLifecycleRestarting();

  @override
  TailscaleState get visibleState => const TailscaleState(
    TailscaleStatus.degraded,
    detail: 'Tailscale reconnecting…',
  );
}

final class TailscaleLifecycleStopping extends TailscaleLifecycleState {
  const TailscaleLifecycleStopping();

  @override
  TailscaleState get visibleState => const TailscaleState(
    TailscaleStatus.starting,
    detail: 'Stopping Tailscale…',
  );
}

final class TailscaleLifecycleFailed extends TailscaleLifecycleState {
  const TailscaleLifecycleFailed(this.error, {this.detail});

  final Object error;
  final String? detail;

  @override
  TailscaleState get visibleState => TailscaleState(
    TailscaleStatus.failed,
    detail: detail ?? error.toString(),
  );
}

TailscaleLifecycleState tailscaleStableLifecycle(TailscaleState state) =>
    switch (state.status) {
      TailscaleStatus.stopped => const TailscaleLifecycleStopped(),
      TailscaleStatus.starting => TailscaleLifecycleStarting(state),
      TailscaleStatus.running => const TailscaleLifecycleRunning(),
      TailscaleStatus.needsAuth => TailscaleLifecycleNeedsAuth(
        state,
        operationPending: false,
      ),
      TailscaleStatus.degraded => TailscaleLifecycleDegraded(state),
      TailscaleStatus.failed => TailscaleLifecycleFailed(
        StateError(state.detail ?? 'Tailscale failed'),
        detail: state.detail,
      ),
    };

sealed class TailscaleHealthState {
  const TailscaleHealthState();
}

final class TailscaleHealthDormant extends TailscaleHealthState {
  const TailscaleHealthDormant();
}

/// One scheduled/probing health operation. The keyed effect is the timer and
/// in-flight guard; counters remain explicit, inspectable state.
final class TailscaleHealthMonitoring extends TailscaleHealthState {
  const TailscaleHealthMonitoring({
    this.missedProbes = 0,
    this.consecutiveDegradedProbes = 0,
    this.lastBackendState,
  });

  final int missedProbes;
  final int consecutiveDegradedProbes;
  final String? lastBackendState;
}

/// Two orthogonal child regions: native-node lifecycle and health monitoring.
final class TailscaleRuntimeState {
  const TailscaleRuntimeState({
    required this.generation,
    required this.lifecycle,
    required this.health,
    required this.hasSavedAuthKey,
    this.lastAutoRestartAt,
  });

  const TailscaleRuntimeState.initial()
    : generation = 0,
      lifecycle = const TailscaleLifecycleStopped(),
      health = const TailscaleHealthDormant(),
      hasSavedAuthKey = false,
      lastAutoRestartAt = null;

  factory TailscaleRuntimeState.fromVisible(TailscaleState state) =>
      TailscaleRuntimeState(
        generation: 0,
        lifecycle: tailscaleStableLifecycle(state),
        health: const TailscaleHealthDormant(),
        hasSavedAuthKey: false,
      );

  final int generation;
  final TailscaleLifecycleState lifecycle;
  final TailscaleHealthState health;

  /// Auth-key content is a secret resource and never enters the state tree.
  final bool hasSavedAuthKey;
  final DateTime? lastAutoRestartAt;

  TailscaleState get visibleState => lifecycle.visibleState;

  bool get nodeOperationPending => switch (lifecycle) {
    TailscaleLifecycleStarting() ||
    TailscaleLifecycleRestarting() ||
    TailscaleLifecycleStopping() => true,
    TailscaleLifecycleNeedsAuth(:final operationPending) => operationPending,
    _ => false,
  };

  TailscaleRuntimeState copyWith({
    int? generation,
    TailscaleLifecycleState? lifecycle,
    TailscaleHealthState? health,
    bool? hasSavedAuthKey,
    DateTime? lastAutoRestartAt,
  }) => TailscaleRuntimeState(
    generation: generation ?? this.generation,
    lifecycle: lifecycle ?? this.lifecycle,
    health: health ?? this.health,
    hasSavedAuthKey: hasSavedAuthKey ?? this.hasSavedAuthKey,
    lastAutoRestartAt: lastAutoRestartAt ?? this.lastAutoRestartAt,
  );
}
