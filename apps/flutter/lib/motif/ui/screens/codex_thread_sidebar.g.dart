// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'codex_thread_sidebar.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$CodexThreadSidebarViewModel with ObservableModelMixin {
  _$CodexThreadSidebarViewModel(
    ObservableSet<String> expandedProjects,
    ObservableSet<String> expandedThreadLists,
    String? seededSelectedProject,
    bool showAllProjects,
  ) : _expandedProjects = expandedProjects,
      _expandedThreadLists = expandedThreadLists,
      _seededSelectedProject = seededSelectedProject,
      _showAllProjects = showAllProjects {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(
        _expandedProjectsKey,
        () => _expandedProjects,
      );
      observationRegisterDebugProperty(
        _expandedThreadListsKey,
        () => _expandedThreadLists,
      );
      observationRegisterDebugProperty(
        _seededSelectedProjectKey,
        () => _seededSelectedProject,
      );
      observationRegisterDebugProperty(
        _showAllProjectsKey,
        () => _showAllProjects,
      );
    }
  }
  final ObservationKey<ObservableSet<String>> _expandedProjectsKey =
      ObservationKey<ObservableSet<String>>(
        'CodexThreadSidebarViewModel.expandedProjects',
      );
  final ObservableSet<String> _expandedProjects;

  ObservableSet<String> get expandedProjects {
    observationAccess(_expandedProjectsKey);
    return _expandedProjects;
  }

  final ObservationKey<ObservableSet<String>> _expandedThreadListsKey =
      ObservationKey<ObservableSet<String>>(
        'CodexThreadSidebarViewModel.expandedThreadLists',
      );
  final ObservableSet<String> _expandedThreadLists;

  ObservableSet<String> get expandedThreadLists {
    observationAccess(_expandedThreadListsKey);
    return _expandedThreadLists;
  }

  final ObservationKey<String?> _seededSelectedProjectKey =
      ObservationKey<String?>(
        'CodexThreadSidebarViewModel.seededSelectedProject',
      );
  String? _seededSelectedProject;

  String? get seededSelectedProject {
    observationAccess(_seededSelectedProjectKey);
    return _seededSelectedProject;
  }

  set seededSelectedProject(String? value) {
    if (_seededSelectedProject == value) return;
    observationMutation(_seededSelectedProjectKey, () {
      _seededSelectedProject = value;
    });
  }

  final ObservationKey<bool> _showAllProjectsKey = ObservationKey<bool>(
    'CodexThreadSidebarViewModel.showAllProjects',
  );
  bool _showAllProjects;

  bool get showAllProjects {
    observationAccess(_showAllProjectsKey);
    return _showAllProjects;
  }

  set showAllProjects(bool value) {
    if (_showAllProjects == value) return;
    observationMutation(_showAllProjectsKey, () {
      _showAllProjects = value;
    });
  }
}

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$CodexThreadSidebar extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$CodexThreadSidebar({super.key});

  Widget build(
    BuildContext context, {
    required CodexThreadSidebarViewModel viewModel,
  });

  bool shouldRecreateStates(covariant _$CodexThreadSidebar oldWidget) => false;

  void didUpdateStates(
    covariant _$CodexThreadSidebar oldWidget, {
    required CodexThreadSidebarViewModel viewModel,
  }) {}

  void disposeStates({required CodexThreadSidebarViewModel viewModel}) {}

  @override
  State<CodexThreadSidebar> createState() => _$CodexThreadSidebarState();
}

final class _$CodexThreadSidebarState extends State<CodexThreadSidebar>
    with ObservationStateMixin<CodexThreadSidebar> {
  late CodexThreadSidebarViewModel _viewModel;
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
  void didUpdateWidget(covariant CodexThreadSidebar oldWidget) {
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

  void _disposeStates(CodexThreadSidebar owner) {
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
