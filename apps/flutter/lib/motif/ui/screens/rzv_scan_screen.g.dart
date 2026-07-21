// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'rzv_scan_screen.dart';

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$RzvScanScreen extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$RzvScanScreen({super.key});

  Widget build(BuildContext context, {required RzvScanCoordinator coordinator});

  bool shouldRecreateStates(covariant _$RzvScanScreen oldWidget) => false;

  void didUpdateStates(
    covariant _$RzvScanScreen oldWidget, {
    required RzvScanCoordinator coordinator,
  }) {}

  void disposeStates({required RzvScanCoordinator coordinator}) {}

  @override
  State<RzvScanScreen> createState() => _$RzvScanScreenState();
}

final class _$RzvScanScreenState extends State<RzvScanScreen>
    with ObservationStateMixin<RzvScanScreen> {
  late RzvScanCoordinator _coordinator;
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
  void didUpdateWidget(covariant RzvScanScreen oldWidget) {
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

  void _disposeStates(RzvScanScreen owner) {
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
