/// Chooses how often the terminal worker publishes snapshots.
///
/// Ordinary remote output is capped below the display refresh rate to limit
/// full-grid snapshot work. User interaction and viewport movement temporarily
/// boost publishing to display cadence so scrolling and local echo stay fluid.
class TerminalFramePacing {
  TerminalFramePacing({
    this.outputInterval = const Duration(milliseconds: 33),
    this.interactiveInterval = const Duration(milliseconds: 16),
    this.interactiveWindow = const Duration(milliseconds: 200),
  });

  final Duration outputInterval;
  final Duration interactiveInterval;
  final Duration interactiveWindow;

  DateTime? _lastInteractionAt;
  int? _lastViewportOffset;

  Duration intervalForOutput({DateTime? now}) {
    final current = now ?? DateTime.now();
    final interactionAt = _lastInteractionAt;
    if (interactionAt != null &&
        current.difference(interactionAt) <= interactiveWindow) {
      return interactiveInterval;
    }
    return outputInterval;
  }

  void noteInteraction({DateTime? at}) {
    _lastInteractionAt = at ?? DateTime.now();
  }

  /// Records viewport movement reported by the latest rendered snapshot.
  /// Initializing the baseline is not itself considered scrolling.
  void observeViewportOffset(int offset, {DateTime? at}) {
    final previous = _lastViewportOffset;
    _lastViewportOffset = offset;
    if (previous != null && previous != offset) {
      noteInteraction(at: at);
    }
  }

  void reset() {
    _lastInteractionAt = null;
    _lastViewportOffset = null;
  }
}
