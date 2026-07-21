// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'terminal_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$TerminalViewModel with ObservableModelMixin {
  _$TerminalViewModel(
    TerminalStreamRuntimeState runtime,
    ObservableList<PtyInfo> ptys,
    ObservableMap<String, String> runningCommand,
    ObservableMap<String, ShellKind> shellKind,
    ObservableMap<String, ShellContext> shellContext,
  ) : _runtime = runtime,
      _ptys = ptys,
      _runningCommand = runningCommand,
      _shellKind = shellKind,
      _shellContext = shellContext {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_runtimeKey, () => _runtime);
      observationRegisterDebugProperty(_ptysKey, () => _ptys);
      observationRegisterDebugProperty(
        _runningCommandKey,
        () => _runningCommand,
      );
      observationRegisterDebugProperty(_shellKindKey, () => _shellKind);
      observationRegisterDebugProperty(_shellContextKey, () => _shellContext);
    }
  }
  final ObservationKey<TerminalStreamRuntimeState> _runtimeKey =
      ObservationKey<TerminalStreamRuntimeState>('TerminalViewModel.runtime');
  TerminalStreamRuntimeState _runtime;

  TerminalStreamRuntimeState get runtime {
    observationAccess(_runtimeKey);
    return _runtime;
  }

  set runtime(TerminalStreamRuntimeState value) {
    if (_runtime == value) return;
    observationMutation(_runtimeKey, () {
      _runtime = value;
    });
  }

  final ObservationKey<ObservableList<PtyInfo>> _ptysKey =
      ObservationKey<ObservableList<PtyInfo>>('TerminalViewModel.ptys');
  final ObservableList<PtyInfo> _ptys;

  ObservableList<PtyInfo> get ptys {
    observationAccess(_ptysKey);
    return _ptys;
  }

  final ObservationKey<ObservableMap<String, String>> _runningCommandKey =
      ObservationKey<ObservableMap<String, String>>(
        'TerminalViewModel.runningCommand',
      );
  final ObservableMap<String, String> _runningCommand;

  ObservableMap<String, String> get runningCommand {
    observationAccess(_runningCommandKey);
    return _runningCommand;
  }

  final ObservationKey<ObservableMap<String, ShellKind>> _shellKindKey =
      ObservationKey<ObservableMap<String, ShellKind>>(
        'TerminalViewModel.shellKind',
      );
  final ObservableMap<String, ShellKind> _shellKind;

  ObservableMap<String, ShellKind> get shellKind {
    observationAccess(_shellKindKey);
    return _shellKind;
  }

  final ObservationKey<ObservableMap<String, ShellContext>> _shellContextKey =
      ObservationKey<ObservableMap<String, ShellContext>>(
        'TerminalViewModel.shellContext',
      );
  final ObservableMap<String, ShellContext> _shellContext;

  ObservableMap<String, ShellContext> get shellContext {
    observationAccess(_shellContextKey);
    return _shellContext;
  }
}
