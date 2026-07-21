// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'remote_port_mapping_sheet.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$_RemotePortFormViewModel with ObservableModelMixin {
  _$_RemotePortFormViewModel(String scheme, String? errorText)
    : _scheme = scheme,
      _errorText = errorText {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_schemeKey, () => _scheme);
      observationRegisterDebugProperty(_errorTextKey, () => _errorText);
    }
  }
  final ObservationKey<String> _schemeKey = ObservationKey<String>(
    '_RemotePortFormViewModel.scheme',
  );
  String _scheme;

  String get scheme {
    observationAccess(_schemeKey);
    return _scheme;
  }

  set scheme(String value) {
    if (_scheme == value) return;
    observationMutation(_schemeKey, () {
      _scheme = value;
    });
  }

  final ObservationKey<String?> _errorTextKey = ObservationKey<String?>(
    '_RemotePortFormViewModel.errorText',
  );
  String? _errorText;

  String? get errorText {
    observationAccess(_errorTextKey);
    return _errorText;
  }

  set errorText(String? value) {
    if (_errorText == value) return;
    observationMutation(_errorTextKey, () {
      _errorText = value;
    });
  }
}

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$_RemotePortMappingsPanel extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_RemotePortMappingsPanel({super.key});

  Widget build(
    BuildContext context, {
    required _RemotePortPanelCoordinator coordinator,
  });

  bool shouldRecreateStates(covariant _$_RemotePortMappingsPanel oldWidget) =>
      false;

  void didUpdateStates(
    covariant _$_RemotePortMappingsPanel oldWidget, {
    required _RemotePortPanelCoordinator coordinator,
  }) {}

  void disposeStates({required _RemotePortPanelCoordinator coordinator}) {}

  @override
  State<_RemotePortMappingsPanel> createState() =>
      _$_RemotePortMappingsPanelState();
}

final class _$_RemotePortMappingsPanelState
    extends State<_RemotePortMappingsPanel>
    with ObservationStateMixin<_RemotePortMappingsPanel> {
  late _RemotePortPanelCoordinator _coordinator;
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
  void didUpdateWidget(covariant _RemotePortMappingsPanel oldWidget) {
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

  void _disposeStates(_RemotePortMappingsPanel owner) {
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

abstract class _$_RemotePortFormModal extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_RemotePortFormModal({super.key});

  Widget build(
    BuildContext context, {
    required TextEditingController portController,
    required _RemotePortFormViewModel viewModel,
  });

  bool shouldRecreateStates(covariant _$_RemotePortFormModal oldWidget) =>
      false;

  void didUpdateStates(
    covariant _$_RemotePortFormModal oldWidget, {
    required TextEditingController portController,
    required _RemotePortFormViewModel viewModel,
  }) {}

  void disposeStates({
    required TextEditingController portController,
    required _RemotePortFormViewModel viewModel,
  }) {}

  @override
  State<_RemotePortFormModal> createState() => _$_RemotePortFormModalState();
}

final class _$_RemotePortFormModalState extends State<_RemotePortFormModal>
    with ObservationStateMixin<_RemotePortFormModal> {
  late TextEditingController _portController;
  bool _hasPortController = false;
  late _RemotePortFormViewModel _viewModel;
  bool _hasViewModel = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasPortController) (name: 'portController', value: _portController),
    if (_hasViewModel) (name: 'viewModel', value: _viewModel),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _portController = widget.createPortController();
      _hasPortController = true;
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
  void didUpdateWidget(covariant _RemotePortFormModal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(
        oldWidget,
        portController: _portController,
        viewModel: _viewModel,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(
        context,
        portController: _portController,
        viewModel: _viewModel,
      );
    });
  }

  void _disposeStates(_RemotePortFormModal owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(
        portController: _portController,
        viewModel: _viewModel,
      ),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
      if (_hasViewModel)
        () {
          _hasViewModel = false;
        },
      if (_hasPortController)
        () {
          _hasPortController = false;
          _portController.dispose();
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
