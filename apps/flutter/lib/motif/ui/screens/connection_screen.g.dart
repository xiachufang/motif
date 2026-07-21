// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connection_screen.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$_ServerRowViewModel with ObservableModelMixin {
  _$_ServerRowViewModel(_ServerPingIndicator pingIndicator)
    : _pingIndicator = pingIndicator {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_pingIndicatorKey, () => _pingIndicator);
    }
  }
  final ObservationKey<_ServerPingIndicator> _pingIndicatorKey =
      ObservationKey<_ServerPingIndicator>('_ServerRowViewModel.pingIndicator');
  _ServerPingIndicator _pingIndicator;

  _ServerPingIndicator get pingIndicator {
    observationAccess(_pingIndicatorKey);
    return _pingIndicator;
  }

  set pingIndicator(_ServerPingIndicator value) {
    if (_pingIndicator == value) return;
    observationMutation(_pingIndicatorKey, () {
      _pingIndicator = value;
    });
  }
}

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$ConnectionScreen extends ObservationStatelessWidget {
  const _$ConnectionScreen({super.key});
}

abstract class _$_ServerRow extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_ServerRow({super.key});

  Widget build(
    BuildContext context, {
    required _ServerRowViewModel viewModel,
    required _ServerPingCoordinator coordinator,
  });

  bool shouldRecreateStates(covariant _$_ServerRow oldWidget) => false;

  void didUpdateStates(
    covariant _$_ServerRow oldWidget, {
    required _ServerRowViewModel viewModel,
    required _ServerPingCoordinator coordinator,
  }) {}

  void disposeStates({
    required _ServerRowViewModel viewModel,
    required _ServerPingCoordinator coordinator,
  }) {}

  @override
  State<_ServerRow> createState() => _$_ServerRowState();
}

final class _$_ServerRowState extends State<_ServerRow>
    with ObservationStateMixin<_ServerRow> {
  late _ServerRowViewModel _viewModel;
  bool _hasViewModel = false;
  late _ServerPingCoordinator _coordinator;
  bool _hasCoordinator = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasViewModel) (name: 'viewModel', value: _viewModel),
    if (_hasCoordinator) (name: 'coordinator', value: _coordinator),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _viewModel = widget.createViewModel();
      _hasViewModel = true;
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
  void didUpdateWidget(covariant _ServerRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(
        oldWidget,
        viewModel: _viewModel,
        coordinator: _coordinator,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(
        context,
        viewModel: _viewModel,
        coordinator: _coordinator,
      );
    });
  }

  void _disposeStates(_ServerRow owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () =>
          owner.disposeStates(viewModel: _viewModel, coordinator: _coordinator),
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
      if (_hasViewModel)
        () {
          _hasViewModel = false;
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
