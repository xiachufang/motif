// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'codex_state.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$CodexState with ObservableModelMixin {
  _$CodexState(
    CodexSidebarMode sidebarMode,
    bool desktopSidebarVisible,
    double sidebarWidth,
  ) : _sidebarMode = sidebarMode,
      _desktopSidebarVisible = desktopSidebarVisible,
      _sidebarWidth = sidebarWidth {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_sidebarModeKey, () => _sidebarMode);
      observationRegisterDebugProperty(
        _desktopSidebarVisibleKey,
        () => _desktopSidebarVisible,
      );
      observationRegisterDebugProperty(_sidebarWidthKey, () => _sidebarWidth);
    }
  }
  final ObservationKey<CodexSidebarMode> _sidebarModeKey =
      ObservationKey<CodexSidebarMode>('CodexState.sidebarMode');
  CodexSidebarMode _sidebarMode;

  CodexSidebarMode get sidebarMode {
    observationAccess(_sidebarModeKey);
    return _sidebarMode;
  }

  set sidebarMode(CodexSidebarMode value) {
    if (_sidebarMode == value) return;
    observationMutation(_sidebarModeKey, () {
      _sidebarMode = value;
    });
  }

  final ObservationKey<bool> _desktopSidebarVisibleKey = ObservationKey<bool>(
    'CodexState.desktopSidebarVisible',
  );
  bool _desktopSidebarVisible;

  bool get desktopSidebarVisible {
    observationAccess(_desktopSidebarVisibleKey);
    return _desktopSidebarVisible;
  }

  set desktopSidebarVisible(bool value) {
    if (_desktopSidebarVisible == value) return;
    observationMutation(_desktopSidebarVisibleKey, () {
      _desktopSidebarVisible = value;
    });
  }

  final ObservationKey<double> _sidebarWidthKey = ObservationKey<double>(
    'CodexState.sidebarWidth',
  );
  double _sidebarWidth;

  double get sidebarWidth {
    observationAccess(_sidebarWidthKey);
    return _sidebarWidth;
  }

  set sidebarWidth(double value) {
    if (_sidebarWidth == value) return;
    observationMutation(_sidebarWidthKey, () {
      _sidebarWidth = value;
    });
  }
}
