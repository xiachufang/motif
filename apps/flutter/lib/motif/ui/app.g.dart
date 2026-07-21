// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app.dart';

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$MotifApp extends ObservationStatelessWidget {
  const _$MotifApp({super.key});
}

abstract class _$_HomeShell extends ObservationStatelessWidget {
  const _$_HomeShell({super.key});
}

abstract class _$_ClientHome extends ObservationStatelessWidget {
  const _$_ClientHome({super.key});
}

abstract class _$_Root extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_Root({super.key});

  Widget build(
    BuildContext context, {
    required _RootStartupCoordinator startup,
  });

  bool shouldRecreateStates(covariant _$_Root oldWidget) => false;

  void didUpdateStates(
    covariant _$_Root oldWidget, {
    required _RootStartupCoordinator startup,
  }) {}

  void disposeStates({required _RootStartupCoordinator startup}) {}

  @override
  State<_Root> createState() => _$_RootState();
}

final class _$_RootState extends State<_Root>
    with ObservationStateMixin<_Root> {
  late _RootStartupCoordinator _startup;
  bool _hasStartup = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasStartup) (name: 'startup', value: _startup),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _startup = widget.createStartup();
      _hasStartup = true;
      _statesReady = true;
    } catch (error, stackTrace) {
      runObservationCallbacks([
        () => Error.throwWithStackTrace(error, stackTrace),
        _disposeCreatedStates,
      ]);
    }
  }

  @override
  void didUpdateWidget(covariant _Root oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(oldWidget, startup: _startup);
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(context, startup: _startup);
    });
  }

  void _disposeStates(_Root owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(startup: _startup),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
      if (_hasStartup)
        () {
          _hasStartup = false;
        },
    ]);
  }

  @override
  void dispose() {
    stopObservation();
    try {
      _disposeStates(widget);
    } finally {
      super.dispose();
    }
  }
}

abstract class _$_PendingSessionOpenListener extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_PendingSessionOpenListener({super.key});

  Widget build(
    BuildContext context, {
    required _PendingSessionOpenCoordinator coordinator,
  });

  bool shouldRecreateStates(
    covariant _$_PendingSessionOpenListener oldWidget,
  ) => false;

  void didUpdateStates(
    covariant _$_PendingSessionOpenListener oldWidget, {
    required _PendingSessionOpenCoordinator coordinator,
  }) {}

  void disposeStates({required _PendingSessionOpenCoordinator coordinator}) {}

  @override
  State<_PendingSessionOpenListener> createState() =>
      _$_PendingSessionOpenListenerState();
}

final class _$_PendingSessionOpenListenerState
    extends State<_PendingSessionOpenListener>
    with ObservationStateMixin<_PendingSessionOpenListener> {
  late _PendingSessionOpenCoordinator _coordinator;
  bool _hasCoordinator = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasCoordinator) (name: 'coordinator', value: _coordinator),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _coordinator = widget.createCoordinator();
      _hasCoordinator = true;
      _statesReady = true;
    } catch (error, stackTrace) {
      runObservationCallbacks([
        () => Error.throwWithStackTrace(error, stackTrace),
        _disposeCreatedStates,
      ]);
    }
  }

  @override
  void didUpdateWidget(covariant _PendingSessionOpenListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(oldWidget, coordinator: _coordinator);
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(context, coordinator: _coordinator);
    });
  }

  void _disposeStates(_PendingSessionOpenListener owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(coordinator: _coordinator),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
      if (_hasCoordinator)
        () {
          _hasCoordinator = false;
        },
    ]);
  }

  @override
  void dispose() {
    stopObservation();
    try {
      _disposeStates(widget);
    } finally {
      super.dispose();
    }
  }
}
