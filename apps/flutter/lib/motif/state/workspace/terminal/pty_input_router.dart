import '../../../log/log.dart';
import '../../../terminal/terminal_session.dart';

/// Routes semantic input to the local terminal surface that owns the current
/// Ghostty parser state for a PTY.
final class PtyInputRouter {
  final Map<String, TerminalInputSink> _sinks = <String, TerminalInputSink>{};

  void register(String ptyId, TerminalInputSink sink) {
    final replacing = _sinks.containsKey(ptyId);
    _sinks[ptyId] = sink;
    Log.d(
      'register input sink pty=$ptyId replacing=$replacing',
      name: 'motif.pty',
    );
  }

  void unregister(String ptyId, [TerminalInputSink? sink]) {
    final current = _sinks[ptyId];
    if (sink != null && current != sink) {
      Log.d('skip unregister stale input sink pty=$ptyId', name: 'motif.pty');
      return;
    }
    _sinks.remove(ptyId);
  }

  bool dispatch(String ptyId, TerminalInputEvent event) {
    final sink = _sinks[ptyId];
    return sink != null && sink(event);
  }

  void clearPty(String ptyId) => _sinks.remove(ptyId);

  void clearAll() => _sinks.clear();
}
