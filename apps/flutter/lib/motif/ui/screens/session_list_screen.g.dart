// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'session_list_screen.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$_ServerHeaderActionsViewModel with ObservableModelMixin {
  _$_ServerHeaderActionsViewModel(bool refreshing) : _refreshing = refreshing {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_refreshingKey, () => _refreshing);
    }
  }
  final ObservationKey<bool> _refreshingKey = ObservationKey<bool>(
    '_ServerHeaderActionsViewModel.refreshing',
  );
  bool _refreshing;

  bool get refreshing {
    observationAccess(_refreshingKey);
    return _refreshing;
  }

  set refreshing(bool value) {
    if (_refreshing == value) return;
    observationMutation(_refreshingKey, () {
      _refreshing = value;
    });
  }
}

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$_ServerSessionSection extends ObservationStatelessWidget {
  const _$_ServerSessionSection({super.key});
}

abstract class _$_ServerHeaderActions extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_ServerHeaderActions({super.key});

  Widget build(
    BuildContext context, {
    required _ServerHeaderActionsViewModel viewModel,
  });

  bool shouldRecreateStates(covariant _$_ServerHeaderActions oldWidget) =>
      false;

  void didUpdateStates(
    covariant _$_ServerHeaderActions oldWidget, {
    required _ServerHeaderActionsViewModel viewModel,
  }) {}

  void disposeStates({required _ServerHeaderActionsViewModel viewModel}) {}

  @override
  State<_ServerHeaderActions> createState() => _$_ServerHeaderActionsState();
}

final class _$_ServerHeaderActionsState extends State<_ServerHeaderActions>
    with ObservationStateMixin<_ServerHeaderActions> {
  late _ServerHeaderActionsViewModel _viewModel;
  bool _hasViewModel = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasViewModel) (name: 'viewModel', value: _viewModel),
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
      _statesReady = true;
    } catch (error, stackTrace) {
      runObservationCallbacks([
        () => Error.throwWithStackTrace(error, stackTrace),
        _disposeCreatedStates,
      ]);
    }
  }

  @override
  void didUpdateWidget(covariant _ServerHeaderActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(oldWidget, viewModel: _viewModel);
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(context, viewModel: _viewModel);
    });
  }

  void _disposeStates(_ServerHeaderActions owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(viewModel: _viewModel),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
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

abstract class _$_SessionListEmptyState extends ObservationStatelessWidget {
  const _$_SessionListEmptyState({super.key});
}
