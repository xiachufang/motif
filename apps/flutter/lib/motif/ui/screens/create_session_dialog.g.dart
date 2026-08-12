// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'create_session_dialog.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$_CreateSessionDialogViewModel with ObservableModelMixin {
  _$_CreateSessionDialogViewModel(bool canCreate) : _canCreate = canCreate {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_canCreateKey, () => _canCreate);
    }
  }
  final ObservationKey<bool> _canCreateKey = ObservationKey<bool>(
    '_CreateSessionDialogViewModel.canCreate',
  );
  bool _canCreate;

  bool get canCreate {
    observationAccess(_canCreateKey);
    return _canCreate;
  }

  set canCreate(bool value) {
    if (_canCreate == value) return;
    observationMutation(_canCreateKey, () {
      _canCreate = value;
    });
  }
}

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$_CreateSessionDialog extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_CreateSessionDialog({super.key});

  Widget build(
    BuildContext context, {
    required TextEditingController nameController,
    required TextEditingController workdirController,
    required _CreateSessionDialogViewModel viewModel,
  });

  bool shouldRecreateStates(covariant _$_CreateSessionDialog oldWidget) =>
      false;

  void didUpdateStates(
    covariant _$_CreateSessionDialog oldWidget, {
    required TextEditingController nameController,
    required TextEditingController workdirController,
    required _CreateSessionDialogViewModel viewModel,
  }) {}

  void disposeStates({
    required TextEditingController nameController,
    required TextEditingController workdirController,
    required _CreateSessionDialogViewModel viewModel,
  }) {}

  @override
  State<_CreateSessionDialog> createState() => _$_CreateSessionDialogState();
}

final class _$_CreateSessionDialogState extends State<_CreateSessionDialog>
    with ObservationStateMixin<_CreateSessionDialog> {
  late TextEditingController _nameController;
  bool _hasNameController = false;
  late TextEditingController _workdirController;
  bool _hasWorkdirController = false;
  late _CreateSessionDialogViewModel _viewModel;
  bool _hasViewModel = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasNameController) (name: 'nameController', value: _nameController),
    if (_hasWorkdirController)
      (name: 'workdirController', value: _workdirController),
    if (_hasViewModel) (name: 'viewModel', value: _viewModel),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _nameController = widget.createNameController();
      _hasNameController = true;
      _workdirController = widget.createWorkdirController();
      _hasWorkdirController = true;
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
  void didUpdateWidget(covariant _CreateSessionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(
        oldWidget,
        nameController: _nameController,
        workdirController: _workdirController,
        viewModel: _viewModel,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(
        context,
        nameController: _nameController,
        workdirController: _workdirController,
        viewModel: _viewModel,
      );
    });
  }

  void _disposeStates(_CreateSessionDialog owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(
        nameController: _nameController,
        workdirController: _workdirController,
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
      if (_hasWorkdirController)
        () {
          _hasWorkdirController = false;
          _workdirController.dispose();
        },
      if (_hasNameController)
        () {
          _hasNameController = false;
          _nameController.dispose();
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
