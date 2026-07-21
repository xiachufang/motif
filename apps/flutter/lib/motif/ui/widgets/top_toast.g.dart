// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'top_toast.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$MotifToastCoordinator with ObservableModelMixin {
  _$MotifToastCoordinator(MotifToastData? toast) : _toast = toast {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_toastKey, () => _toast);
    }
  }
  final ObservationKey<MotifToastData?> _toastKey =
      ObservationKey<MotifToastData?>('MotifToastCoordinator.toast');
  MotifToastData? _toast;

  MotifToastData? get toast {
    observationAccess(_toastKey);
    return _toast;
  }

  set toast(MotifToastData? value) {
    if (_toast == value) return;
    observationMutation(_toastKey, () {
      _toast = value;
    });
  }
}

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$MotifToastHost extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$MotifToastHost({super.key});

  Widget build(
    BuildContext context, {
    required MotifToastCoordinator coordinator,
  });

  bool shouldRecreateStates(covariant _$MotifToastHost oldWidget) => false;

  void didUpdateStates(
    covariant _$MotifToastHost oldWidget, {
    required MotifToastCoordinator coordinator,
  }) {}

  void disposeStates({required MotifToastCoordinator coordinator}) {}

  @override
  State<MotifToastHost> createState() => _$MotifToastHostState();
}

final class _$MotifToastHostState extends State<MotifToastHost>
    with ObservationStateMixin<MotifToastHost> {
  late MotifToastCoordinator _coordinator;
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
  void didUpdateWidget(covariant MotifToastHost oldWidget) {
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

  void _disposeStates(MotifToastHost owner) {
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
          _coordinator.dispose();
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
