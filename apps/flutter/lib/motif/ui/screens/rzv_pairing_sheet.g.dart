// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'rzv_pairing_sheet.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$_RzvPairingViewModel with ObservableModelMixin {
  _$_RzvPairingViewModel(MotifPairingPayload? parsed, String? error, bool busy)
    : _parsed = parsed,
      _error = error,
      _busy = busy {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_parsedKey, () => _parsed);
      observationRegisterDebugProperty(_errorKey, () => _error);
      observationRegisterDebugProperty(_busyKey, () => _busy);
    }
  }
  final ObservationKey<MotifPairingPayload?> _parsedKey =
      ObservationKey<MotifPairingPayload?>('_RzvPairingViewModel.parsed');
  MotifPairingPayload? _parsed;

  MotifPairingPayload? get parsed {
    observationAccess(_parsedKey);
    return _parsed;
  }

  set parsed(MotifPairingPayload? value) {
    if (_parsed == value) return;
    observationMutation(_parsedKey, () {
      _parsed = value;
    });
  }

  final ObservationKey<String?> _errorKey = ObservationKey<String?>(
    '_RzvPairingViewModel.error',
  );
  String? _error;

  String? get error {
    observationAccess(_errorKey);
    return _error;
  }

  set error(String? value) {
    if (_error == value) return;
    observationMutation(_errorKey, () {
      _error = value;
    });
  }

  final ObservationKey<bool> _busyKey = ObservationKey<bool>(
    '_RzvPairingViewModel.busy',
  );
  bool _busy;

  bool get busy {
    observationAccess(_busyKey);
    return _busy;
  }

  set busy(bool value) {
    if (_busy == value) return;
    observationMutation(_busyKey, () {
      _busy = value;
    });
  }
}

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$_RzvPairingSheet extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_RzvPairingSheet({super.key});

  Widget build(
    BuildContext context, {
    required TextEditingController controller,
    required _RzvPairingViewModel viewModel,
  });

  bool shouldRecreateStates(covariant _$_RzvPairingSheet oldWidget) => false;

  void didUpdateStates(
    covariant _$_RzvPairingSheet oldWidget, {
    required TextEditingController controller,
    required _RzvPairingViewModel viewModel,
  }) {}

  void disposeStates({
    required TextEditingController controller,
    required _RzvPairingViewModel viewModel,
  }) {}

  @override
  State<_RzvPairingSheet> createState() => _$_RzvPairingSheetState();
}

final class _$_RzvPairingSheetState extends State<_RzvPairingSheet>
    with ObservationStateMixin<_RzvPairingSheet> {
  late TextEditingController _controller;
  bool _hasController = false;
  late _RzvPairingViewModel _viewModel;
  bool _hasViewModel = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasController) (name: 'controller', value: _controller),
    if (_hasViewModel) (name: 'viewModel', value: _viewModel),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _controller = widget.createController();
      _hasController = true;
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
  void didUpdateWidget(covariant _RzvPairingSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(
        oldWidget,
        controller: _controller,
        viewModel: _viewModel,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(
        context,
        controller: _controller,
        viewModel: _viewModel,
      );
    });
  }

  void _disposeStates(_RzvPairingSheet owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(controller: _controller, viewModel: _viewModel),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
      if (_hasViewModel)
        () {
          _hasViewModel = false;
        },
      if (_hasController)
        () {
          _hasController = false;
          _controller.dispose();
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
