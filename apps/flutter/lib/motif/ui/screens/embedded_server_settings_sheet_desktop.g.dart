// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'embedded_server_settings_sheet_desktop.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$_PushTokensViewModel with ObservableModelMixin {
  _$_PushTokensViewModel(
    Future<List<RegisteredPushToken>> tokens,
    ObservableSet<String> sending,
  ) : _tokens = tokens,
      _sending = sending {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_tokensKey, () => _tokens);
      observationRegisterDebugProperty(_sendingKey, () => _sending);
    }
  }
  final ObservationKey<Future<List<RegisteredPushToken>>> _tokensKey =
      ObservationKey<Future<List<RegisteredPushToken>>>(
        '_PushTokensViewModel.tokens',
      );
  Future<List<RegisteredPushToken>> _tokens;

  Future<List<RegisteredPushToken>> get tokens {
    observationAccess(_tokensKey);
    return _tokens;
  }

  set tokens(Future<List<RegisteredPushToken>> value) {
    if (_tokens == value) return;
    observationMutation(_tokensKey, () {
      _tokens = value;
    });
  }

  final ObservationKey<ObservableSet<String>> _sendingKey =
      ObservationKey<ObservableSet<String>>('_PushTokensViewModel.sending');
  final ObservableSet<String> _sending;

  ObservableSet<String> get sending {
    observationAccess(_sendingKey);
    return _sending;
  }
}

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$_PushTokensView extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_PushTokensView({super.key});

  Widget build(BuildContext context, {required _PushTokensViewModel viewModel});

  bool shouldRecreateStates(covariant _$_PushTokensView oldWidget) => false;

  void didUpdateStates(
    covariant _$_PushTokensView oldWidget, {
    required _PushTokensViewModel viewModel,
  }) {}

  void disposeStates({required _PushTokensViewModel viewModel}) {}

  @override
  State<_PushTokensView> createState() => _$_PushTokensViewState();
}

final class _$_PushTokensViewState extends State<_PushTokensView>
    with ObservationStateMixin<_PushTokensView> {
  late _PushTokensViewModel _viewModel;
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
  void didUpdateWidget(covariant _PushTokensView oldWidget) {
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

  void _disposeStates(_PushTokensView owner) {
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

abstract class _$EmbeddedServerPage extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$EmbeddedServerPage({super.key});

  Widget build(
    BuildContext context, {
    required ScrollController scrollController,
  });

  bool shouldRecreateStates(covariant _$EmbeddedServerPage oldWidget) => false;

  void didUpdateStates(
    covariant _$EmbeddedServerPage oldWidget, {
    required ScrollController scrollController,
  }) {}

  void disposeStates({required ScrollController scrollController}) {}

  @override
  State<EmbeddedServerPage> createState() => _$EmbeddedServerPageState();
}

final class _$EmbeddedServerPageState extends State<EmbeddedServerPage>
    with ObservationStateMixin<EmbeddedServerPage> {
  late ScrollController _scrollController;
  bool _hasScrollController = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasScrollController)
      (name: 'scrollController', value: _scrollController),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _scrollController = widget.createScrollController();
      _hasScrollController = true;
      _statesReady = true;
    } catch (error, stackTrace) {
      runObservationCallbacks([
        () => Error.throwWithStackTrace(error, stackTrace),
        _disposeCreatedStates,
      ]);
    }
  }

  @override
  void didUpdateWidget(covariant EmbeddedServerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(oldWidget, scrollController: _scrollController);
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(context, scrollController: _scrollController);
    });
  }

  void _disposeStates(EmbeddedServerPage owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(scrollController: _scrollController),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
      if (_hasScrollController)
        () {
          _hasScrollController = false;
          _scrollController.dispose();
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
