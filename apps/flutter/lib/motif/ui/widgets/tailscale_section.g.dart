// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tailscale_section.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$_TailscaleSetupViewModel with ObservableModelMixin {
  _$_TailscaleSetupViewModel(
    bool browserLoginRequested,
    String authKey,
    String? startError,
  ) : _browserLoginRequested = browserLoginRequested,
      _authKey = authKey,
      _startError = startError {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(
        _browserLoginRequestedKey,
        () => _browserLoginRequested,
      );
      observationRegisterDebugProperty(_authKeyKey, () => _authKey);
      observationRegisterDebugProperty(_startErrorKey, () => _startError);
    }
  }
  final ObservationKey<bool> _browserLoginRequestedKey = ObservationKey<bool>(
    '_TailscaleSetupViewModel.browserLoginRequested',
  );
  bool _browserLoginRequested;

  bool get browserLoginRequested {
    observationAccess(_browserLoginRequestedKey);
    return _browserLoginRequested;
  }

  set browserLoginRequested(bool value) {
    if (_browserLoginRequested == value) return;
    observationMutation(_browserLoginRequestedKey, () {
      _browserLoginRequested = value;
    });
  }

  final ObservationKey<String> _authKeyKey = ObservationKey<String>(
    '_TailscaleSetupViewModel.authKey',
  );
  String _authKey;

  String get authKey {
    observationAccess(_authKeyKey);
    return _authKey;
  }

  set authKey(String value) {
    if (_authKey == value) return;
    observationMutation(_authKeyKey, () {
      _authKey = value;
    });
  }

  final ObservationKey<String?> _startErrorKey = ObservationKey<String?>(
    '_TailscaleSetupViewModel.startError',
  );
  String? _startError;

  String? get startError {
    observationAccess(_startErrorKey);
    return _startError;
  }

  set startError(String? value) {
    if (_startError == value) return;
    observationMutation(_startErrorKey, () {
      _startError = value;
    });
  }
}

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$TailscaleSection extends ObservationStatelessWidget {
  const _$TailscaleSection({super.key});
}

abstract class _$_TailscaleConnectionSheet extends ObservationStatelessWidget {
  const _$_TailscaleConnectionSheet({super.key});
}

abstract class _$_TailscaleSetupSheet extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_TailscaleSetupSheet({super.key});

  Widget build(
    BuildContext context, {
    required TextEditingController keyController,
    required _TailscaleSetupViewModel viewModel,
    required _TailscaleSetupEffects effects,
  });

  bool shouldRecreateStates(covariant _$_TailscaleSetupSheet oldWidget) =>
      false;

  void didUpdateStates(
    covariant _$_TailscaleSetupSheet oldWidget, {
    required TextEditingController keyController,
    required _TailscaleSetupViewModel viewModel,
    required _TailscaleSetupEffects effects,
  }) {}

  void disposeStates({
    required TextEditingController keyController,
    required _TailscaleSetupViewModel viewModel,
    required _TailscaleSetupEffects effects,
  }) {}

  @override
  State<_TailscaleSetupSheet> createState() => _$_TailscaleSetupSheetState();
}

final class _$_TailscaleSetupSheetState extends State<_TailscaleSetupSheet>
    with ObservationStateMixin<_TailscaleSetupSheet> {
  late TextEditingController _keyController;
  bool _hasKeyController = false;
  late _TailscaleSetupViewModel _viewModel;
  bool _hasViewModel = false;
  late _TailscaleSetupEffects _effects;
  bool _hasEffects = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasKeyController) (name: 'keyController', value: _keyController),
    if (_hasViewModel) (name: 'viewModel', value: _viewModel),
    if (_hasEffects) (name: 'effects', value: _effects),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _keyController = widget.createKeyController();
      _hasKeyController = true;
      _viewModel = widget.createViewModel();
      _hasViewModel = true;
      _effects = widget.createEffects();
      _hasEffects = true;
      _statesReady = true;
    } catch (error, stackTrace) {
      runObservationCallbacks([
        () => Error.throwWithStackTrace(error, stackTrace),
        _disposeCreatedStates,
      ]);
    }
  }

  @override
  void didUpdateWidget(covariant _TailscaleSetupSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(
        oldWidget,
        keyController: _keyController,
        viewModel: _viewModel,
        effects: _effects,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(
        context,
        keyController: _keyController,
        viewModel: _viewModel,
        effects: _effects,
      );
    });
  }

  void _disposeStates(_TailscaleSetupSheet owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(
        keyController: _keyController,
        viewModel: _viewModel,
        effects: _effects,
      ),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
      if (_hasEffects)
        () {
          _hasEffects = false;
        },
      if (_hasViewModel)
        () {
          _hasViewModel = false;
        },
      if (_hasKeyController)
        () {
          _hasKeyController = false;
          _keyController.dispose();
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

abstract class _$_TailscaleDetailsSheet extends ObservationStatelessWidget {
  const _$_TailscaleDetailsSheet({super.key});
}
