part of 'workspace_connection_controller.dart';

/// Workspace palette advertisement and foreground-primary reclaim.
extension _WorkspaceConnectionControllerPalette
    on WorkspaceConnectionController {
  void _setTerminalPaletteImpl({String? fg, String? bg, String? theme}) {
    if (fg == termFg && bg == termBg && theme == termTheme) return;
    termFg = fg;
    termBg = bg;
    termTheme = theme;
    final rpc = _rpc;
    if (rpc == null || _state is! ConnAttached) return;
    unawaited(
      rpc
          .call('session.set_palette', {
            'term_fg': ?fg,
            'term_bg': ?bg,
            'theme': ?theme,
          })
          .catchError((_) => <String, Object?>{}),
    );
  }

  void _reclaimPrimary() {
    final rpc = _rpc;
    final viewId = _viewState.activeViewId;
    if (!isForeground ||
        rpc == null ||
        viewId == null ||
        _state is! ConnAttached) {
      return;
    }
    unawaited(
      rpc
          .call('view.activate', {'view_id': viewId})
          .catchError((_) => <String, Object?>{}),
    );
    if (termFg != null || termBg != null || termTheme != null) {
      unawaited(
        rpc
            .call('session.set_palette', {
              'term_fg': ?termFg,
              'term_bg': ?termBg,
              'theme': ?termTheme,
            })
            .catchError((_) => <String, Object?>{}),
      );
    }
  }
}
