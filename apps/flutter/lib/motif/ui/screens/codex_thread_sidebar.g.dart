// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'codex_thread_sidebar.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$CodexThreadSidebarViewModel with ObservableModelMixin {
  _$CodexThreadSidebarViewModel(
    ObservableSet<String> expandedProjects,
    ObservableMap<String, int> visibleThreadCounts,
    ObservableList<CodexThread> queryResults,
    String? seededSelectedProject,
    bool showAllProjects,
    bool showSearch,
    bool showArchived,
    String query,
    bool queryLoading,
    String? queryError,
  ) : _expandedProjects = expandedProjects,
      _visibleThreadCounts = visibleThreadCounts,
      _queryResults = queryResults,
      _seededSelectedProject = seededSelectedProject,
      _showAllProjects = showAllProjects,
      _showSearch = showSearch,
      _showArchived = showArchived,
      _query = query,
      _queryLoading = queryLoading,
      _queryError = queryError {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(
        _expandedProjectsKey,
        () => _expandedProjects,
      );
      observationRegisterDebugProperty(
        _visibleThreadCountsKey,
        () => _visibleThreadCounts,
      );
      observationRegisterDebugProperty(_queryResultsKey, () => _queryResults);
      observationRegisterDebugProperty(
        _seededSelectedProjectKey,
        () => _seededSelectedProject,
      );
      observationRegisterDebugProperty(
        _showAllProjectsKey,
        () => _showAllProjects,
      );
      observationRegisterDebugProperty(_showSearchKey, () => _showSearch);
      observationRegisterDebugProperty(_showArchivedKey, () => _showArchived);
      observationRegisterDebugProperty(_queryKey, () => _query);
      observationRegisterDebugProperty(_queryLoadingKey, () => _queryLoading);
      observationRegisterDebugProperty(_queryErrorKey, () => _queryError);
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

  final ObservationKey<ObservableMap<String, int>> _visibleThreadCountsKey =
      ObservationKey<ObservableMap<String, int>>(
        'CodexThreadSidebarViewModel.visibleThreadCounts',
      );
  final ObservableMap<String, int> _visibleThreadCounts;

  ObservableMap<String, int> get visibleThreadCounts {
    observationAccess(_visibleThreadCountsKey);
    return _visibleThreadCounts;
  }

  final ObservationKey<ObservableList<CodexThread>> _queryResultsKey =
      ObservationKey<ObservableList<CodexThread>>(
        'CodexThreadSidebarViewModel.queryResults',
      );
  final ObservableList<CodexThread> _queryResults;

  ObservableList<CodexThread> get queryResults {
    observationAccess(_queryResultsKey);
    return _queryResults;
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

  final ObservationKey<bool> _showSearchKey = ObservationKey<bool>(
    'CodexThreadSidebarViewModel.showSearch',
  );
  bool _showSearch;

  bool get showSearch {
    observationAccess(_showSearchKey);
    return _showSearch;
  }

  set showSearch(bool value) {
    if (_showSearch == value) return;
    observationMutation(_showSearchKey, () {
      _showSearch = value;
    });
  }

  final ObservationKey<bool> _showArchivedKey = ObservationKey<bool>(
    'CodexThreadSidebarViewModel.showArchived',
  );
  bool _showArchived;

  bool get showArchived {
    observationAccess(_showArchivedKey);
    return _showArchived;
  }

  set showArchived(bool value) {
    if (_showArchived == value) return;
    observationMutation(_showArchivedKey, () {
      _showArchived = value;
    });
  }

  final ObservationKey<String> _queryKey = ObservationKey<String>(
    'CodexThreadSidebarViewModel.query',
  );
  String _query;

  String get query {
    observationAccess(_queryKey);
    return _query;
  }

  set query(String value) {
    if (_query == value) return;
    observationMutation(_queryKey, () {
      _query = value;
    });
  }

  final ObservationKey<bool> _queryLoadingKey = ObservationKey<bool>(
    'CodexThreadSidebarViewModel.queryLoading',
  );
  bool _queryLoading;

  bool get queryLoading {
    observationAccess(_queryLoadingKey);
    return _queryLoading;
  }

  set queryLoading(bool value) {
    if (_queryLoading == value) return;
    observationMutation(_queryLoadingKey, () {
      _queryLoading = value;
    });
  }

  final ObservationKey<String?> _queryErrorKey = ObservationKey<String?>(
    'CodexThreadSidebarViewModel.queryError',
  );
  String? _queryError;

  String? get queryError {
    observationAccess(_queryErrorKey);
    return _queryError;
  }

  set queryError(String? value) {
    if (_queryError == value) return;
    observationMutation(_queryErrorKey, () {
      _queryError = value;
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
