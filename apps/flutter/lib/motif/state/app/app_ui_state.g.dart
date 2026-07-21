// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_ui_state.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$AppShellViewModel with ObservableModelMixin {
  _$AppShellViewModel(
    AppViewMode viewMode,
    AppLifecyclePhase lifecycle,
    PendingSessionOpen? pendingSessionOpen,
    SessionSidebarViewModel sidebar,
  ) : _viewMode = viewMode,
      _lifecycle = lifecycle,
      _pendingSessionOpen = pendingSessionOpen,
      _sidebar = sidebar {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_viewModeKey, () => _viewMode);
      observationRegisterDebugProperty(_lifecycleKey, () => _lifecycle);
      observationRegisterDebugProperty(
        _pendingSessionOpenKey,
        () => _pendingSessionOpen,
      );
      observationRegisterDebugProperty(_sidebarKey, () => _sidebar);
    }
  }
  final ObservationKey<AppViewMode> _viewModeKey = ObservationKey<AppViewMode>(
    'AppShellViewModel.viewMode',
  );
  AppViewMode _viewMode;

  AppViewMode get viewMode {
    observationAccess(_viewModeKey);
    return _viewMode;
  }

  set viewMode(AppViewMode value) {
    if (_viewMode == value) return;
    observationMutation(_viewModeKey, () {
      _viewMode = value;
    });
  }

  final ObservationKey<AppLifecyclePhase> _lifecycleKey =
      ObservationKey<AppLifecyclePhase>('AppShellViewModel.lifecycle');
  AppLifecyclePhase _lifecycle;

  AppLifecyclePhase get lifecycle {
    observationAccess(_lifecycleKey);
    return _lifecycle;
  }

  set lifecycle(AppLifecyclePhase value) {
    if (_lifecycle == value) return;
    observationMutation(_lifecycleKey, () {
      _lifecycle = value;
    });
  }

  final ObservationKey<PendingSessionOpen?> _pendingSessionOpenKey =
      ObservationKey<PendingSessionOpen?>(
        'AppShellViewModel.pendingSessionOpen',
      );
  PendingSessionOpen? _pendingSessionOpen;

  PendingSessionOpen? get pendingSessionOpen {
    observationAccess(_pendingSessionOpenKey);
    return _pendingSessionOpen;
  }

  set pendingSessionOpen(PendingSessionOpen? value) {
    if (_pendingSessionOpen == value) return;
    observationMutation(_pendingSessionOpenKey, () {
      _pendingSessionOpen = value;
    });
  }

  final ObservationKey<SessionSidebarViewModel> _sidebarKey =
      ObservationKey<SessionSidebarViewModel>('AppShellViewModel.sidebar');
  final SessionSidebarViewModel _sidebar;

  SessionSidebarViewModel get sidebar {
    observationAccess(_sidebarKey);
    return _sidebar;
  }
}

abstract class _$SessionSidebarViewModel with ObservableModelMixin {
  _$SessionSidebarViewModel(
    bool showSessions,
    bool showFileTree,
    bool showGitDiff,
    bool showBottomBar,
    double width,
    double splitFraction,
    double firstSplitFraction,
    double secondSplitFraction,
  ) : _showSessions = showSessions,
      _showFileTree = showFileTree,
      _showGitDiff = showGitDiff,
      _showBottomBar = showBottomBar,
      _width = width,
      _splitFraction = splitFraction,
      _firstSplitFraction = firstSplitFraction,
      _secondSplitFraction = secondSplitFraction {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_showSessionsKey, () => _showSessions);
      observationRegisterDebugProperty(_showFileTreeKey, () => _showFileTree);
      observationRegisterDebugProperty(_showGitDiffKey, () => _showGitDiff);
      observationRegisterDebugProperty(_showBottomBarKey, () => _showBottomBar);
      observationRegisterDebugProperty(_widthKey, () => _width);
      observationRegisterDebugProperty(_splitFractionKey, () => _splitFraction);
      observationRegisterDebugProperty(
        _firstSplitFractionKey,
        () => _firstSplitFraction,
      );
      observationRegisterDebugProperty(
        _secondSplitFractionKey,
        () => _secondSplitFraction,
      );
    }
  }
  final ObservationKey<bool> _showSessionsKey = ObservationKey<bool>(
    'SessionSidebarViewModel.showSessions',
  );
  bool _showSessions;

  bool get showSessions {
    observationAccess(_showSessionsKey);
    return _showSessions;
  }

  set showSessions(bool value) {
    if (_showSessions == value) return;
    observationMutation(_showSessionsKey, () {
      _showSessions = value;
    });
  }

  final ObservationKey<bool> _showFileTreeKey = ObservationKey<bool>(
    'SessionSidebarViewModel.showFileTree',
  );
  bool _showFileTree;

  bool get showFileTree {
    observationAccess(_showFileTreeKey);
    return _showFileTree;
  }

  set showFileTree(bool value) {
    if (_showFileTree == value) return;
    observationMutation(_showFileTreeKey, () {
      _showFileTree = value;
    });
  }

  final ObservationKey<bool> _showGitDiffKey = ObservationKey<bool>(
    'SessionSidebarViewModel.showGitDiff',
  );
  bool _showGitDiff;

  bool get showGitDiff {
    observationAccess(_showGitDiffKey);
    return _showGitDiff;
  }

  set showGitDiff(bool value) {
    if (_showGitDiff == value) return;
    observationMutation(_showGitDiffKey, () {
      _showGitDiff = value;
    });
  }

  final ObservationKey<bool> _showBottomBarKey = ObservationKey<bool>(
    'SessionSidebarViewModel.showBottomBar',
  );
  bool _showBottomBar;

  bool get showBottomBar {
    observationAccess(_showBottomBarKey);
    return _showBottomBar;
  }

  set showBottomBar(bool value) {
    if (_showBottomBar == value) return;
    observationMutation(_showBottomBarKey, () {
      _showBottomBar = value;
    });
  }

  final ObservationKey<double> _widthKey = ObservationKey<double>(
    'SessionSidebarViewModel.width',
  );
  double _width;

  double get width {
    observationAccess(_widthKey);
    return _width;
  }

  set width(double value) {
    if (_width == value) return;
    observationMutation(_widthKey, () {
      _width = value;
    });
  }

  final ObservationKey<double> _splitFractionKey = ObservationKey<double>(
    'SessionSidebarViewModel.splitFraction',
  );
  double _splitFraction;

  double get splitFraction {
    observationAccess(_splitFractionKey);
    return _splitFraction;
  }

  set splitFraction(double value) {
    if (_splitFraction == value) return;
    observationMutation(_splitFractionKey, () {
      _splitFraction = value;
    });
  }

  final ObservationKey<double> _firstSplitFractionKey = ObservationKey<double>(
    'SessionSidebarViewModel.firstSplitFraction',
  );
  double _firstSplitFraction;

  double get firstSplitFraction {
    observationAccess(_firstSplitFractionKey);
    return _firstSplitFraction;
  }

  set firstSplitFraction(double value) {
    if (_firstSplitFraction == value) return;
    observationMutation(_firstSplitFractionKey, () {
      _firstSplitFraction = value;
    });
  }

  final ObservationKey<double> _secondSplitFractionKey = ObservationKey<double>(
    'SessionSidebarViewModel.secondSplitFraction',
  );
  double _secondSplitFraction;

  double get secondSplitFraction {
    observationAccess(_secondSplitFractionKey);
    return _secondSplitFraction;
  }

  set secondSplitFraction(double value) {
    if (_secondSplitFraction == value) return;
    observationMutation(_secondSplitFractionKey, () {
      _secondSplitFraction = value;
    });
  }
}
