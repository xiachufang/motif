// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notification_banner.dart';

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$NotificationBannerHost extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$NotificationBannerHost({super.key});

  Widget build(
    BuildContext context, {
    required NotificationBannerCoordinator coordinator,
  });

  bool shouldRecreateStates(covariant _$NotificationBannerHost oldWidget) =>
      false;

  void didUpdateStates(
    covariant _$NotificationBannerHost oldWidget, {
    required NotificationBannerCoordinator coordinator,
  }) {}

  void disposeStates({required NotificationBannerCoordinator coordinator}) {}

  @override
  State<NotificationBannerHost> createState() =>
      _$NotificationBannerHostState();
}

final class _$NotificationBannerHostState extends State<NotificationBannerHost>
    with ObservationStateMixin<NotificationBannerHost> {
  late NotificationBannerCoordinator _coordinator;
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
  void didUpdateWidget(covariant NotificationBannerHost oldWidget) {
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

  void _disposeStates(NotificationBannerHost owner) {
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
