import 'package:flutter_observation/flutter_observation.dart';

part 'codex_state.g.dart';

enum CodexSidebarMode { projects, timeline }

/// Process-wide Codex UI preferences.
///
/// Connection and thread state intentionally live in [CodexSessionState]
/// instances instead of this object so separate Motif Codex sessions cannot
/// leak runtime data into one another.
@ObservableModel()
class CodexState extends _$CodexState {
  CodexState({
    CodexSidebarMode sidebarMode = CodexSidebarMode.projects,
    bool desktopSidebarVisible = true,
    double sidebarWidth = 340,
  }) : super(sidebarMode, desktopSidebarVisible, sidebarWidth);
}
