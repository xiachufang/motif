sealed class ViewActivationState {
  const ViewActivationState();
}

final class ViewActivationIdle extends ViewActivationState {
  const ViewActivationIdle();
}

final class ViewActivationPending extends ViewActivationState {
  const ViewActivationPending({
    required this.viewId,
    required this.previousViewId,
    required this.awaitConfirmation,
  });

  final String? viewId;
  final String? previousViewId;
  final bool awaitConfirmation;
}

final class ViewActivationFailed extends ViewActivationState {
  const ViewActivationFailed({
    required this.viewId,
    required this.previousViewId,
    required this.error,
    required this.stackTrace,
  });

  final String? viewId;
  final String? previousViewId;
  final Object error;
  final StackTrace stackTrace;
}

final class ViewRuntimeState {
  const ViewRuntimeState({
    required this.generation,
    required this.activation,
    required this.pendingLocalViewId,
  });

  const ViewRuntimeState.initial()
    : generation = 0,
      activation = const ViewActivationIdle(),
      pendingLocalViewId = null;

  final int generation;
  final ViewActivationState activation;
  final String? pendingLocalViewId;

  ViewRuntimeState copyWith({
    int? generation,
    ViewActivationState? activation,
    String? pendingLocalViewId,
    bool clearPendingLocalViewId = false,
  }) => ViewRuntimeState(
    generation: generation ?? this.generation,
    activation: activation ?? this.activation,
    pendingLocalViewId: clearPendingLocalViewId
        ? null
        : pendingLocalViewId ?? this.pendingLocalViewId,
  );
}
