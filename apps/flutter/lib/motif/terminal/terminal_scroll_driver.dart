import 'dart:math' as math;

import 'terminal_snapshot.dart';

class TerminalScrollAccumulator {
  double _pixelRemainder = 0;

  int applyPixelDelta(double pixels, double rowHeight) {
    if (rowHeight <= 0 || pixels == 0) return 0;
    _pixelRemainder += pixels;
    final rows = (_pixelRemainder / rowHeight).truncate();
    if (rows != 0) {
      _pixelRemainder -= rows * rowHeight;
    }
    return rows;
  }

  void reset() {
    _pixelRemainder = 0;
  }
}

double touchMoveDeltaToScrollPixels(double deltaY) => -deltaY;

/// Screen rows needed to paint a fractional terminal viewport.
///
/// The leading edge starts at `floor(offset)`. The trailing edge deliberately
/// includes `ceil(offset + visibleRows)`, providing one bottom overscan row so
/// the painter can fill the clipped lower edge instead of exposing a gap.
({int first, int last}) terminalFractionalViewportRowRange({
  required double viewportOffset,
  required int visibleRows,
  int totalRows = 0,
}) {
  if (visibleRows <= 0) return (first: 0, last: -1);
  final first = viewportOffset.floor();
  var last = (viewportOffset + visibleRows).ceil();
  if (totalRows > 0) last = math.min(last, totalRows - 1);
  return (first: first, last: last);
}

/// Continuous scrollback position layered over Ghostty's integer-row viewport.
///
/// Ghostty remains the source of truth for terminal history and is asked to
/// load an integer viewport near [viewportOffset]. Flutter keeps the fractional
/// part so direct-touch and trackpad scrolling can stop between terminal rows.
class TerminalSmoothScrollPosition {
  double? _viewportOffset;
  int? _requestedOffset;
  int _maxOffset = 0;

  bool get initialized => _viewportOffset != null;

  double get viewportOffset => _viewportOffset ?? 0;

  int get requestedOffset => _requestedOffset ?? 0;

  int get maxOffset => _maxOffset;

  bool get isFractional =>
      initialized && (viewportOffset - viewportOffset.round()).abs() > 0.0001;

  void synchronize({
    required int viewportOffset,
    required int maxOffset,
    bool followLatest = false,
  }) {
    _maxOffset = math.max(0, maxOffset);
    if (_viewportOffset == null || followLatest) {
      _viewportOffset = viewportOffset.clamp(0, _maxOffset).toDouble();
      _requestedOffset = viewportOffset.clamp(0, _maxOffset);
      return;
    }
    _viewportOffset = _viewportOffset!.clamp(0.0, _maxOffset.toDouble());
    _requestedOffset = (_requestedOffset ?? viewportOffset).clamp(
      0,
      _maxOffset,
    );
  }

  TerminalSmoothScrollUpdate applyPixelDelta(double pixels, double rowHeight) {
    final current = _viewportOffset;
    if (current == null || rowHeight <= 0 || pixels == 0) {
      return TerminalSmoothScrollUpdate(
        viewportOffset: current ?? 0,
        requestedOffset: _requestedOffset ?? 0,
        rowDelta: 0,
        changed: false,
      );
    }
    final next = (current + pixels / rowHeight).clamp(
      0.0,
      _maxOffset.toDouble(),
    );
    if ((next - current).abs() <= 0.000001) {
      return TerminalSmoothScrollUpdate(
        viewportOffset: current,
        requestedOffset: _requestedOffset ?? current.round(),
        rowDelta: 0,
        changed: false,
      );
    }

    // Load the newly exposed edge immediately. The row cache combines this
    // integer viewport with the previous one to paint N+1 partially visible
    // rows while the logical terminal itself continues to use N rows.
    final target = next > current ? next.ceil() : next.floor();
    final rowDelta = requestOffset(target);
    _viewportOffset = next;
    return TerminalSmoothScrollUpdate(
      viewportOffset: next,
      requestedOffset: _requestedOffset!,
      rowDelta: rowDelta,
      changed: true,
    );
  }

  /// Records an absolute integer viewport request and returns its relative
  /// delta for Ghostty's scroll API.
  int requestOffset(int target) {
    final clamped = target.clamp(0, _maxOffset);
    final previous = _requestedOffset ?? _viewportOffset?.round() ?? clamped;
    _requestedOffset = clamped;
    return clamped - previous;
  }

  void reset() {
    _viewportOffset = null;
    _requestedOffset = null;
    _maxOffset = 0;
  }
}

class TerminalSmoothScrollUpdate {
  final double viewportOffset;
  final int requestedOffset;
  final int rowDelta;
  final bool changed;

  const TerminalSmoothScrollUpdate({
    required this.viewportOffset,
    required this.requestedOffset,
    required this.rowDelta,
    required this.changed,
  });
}

/// Small cache of adjacent integer viewport snapshots used to paint a
/// fractional viewport without exposing an empty strip at either edge.
class TerminalViewportRowCache {
  final Map<int, TerminalSnapshotRow> _rows = <int, TerminalSnapshotRow>{};
  int? _cols;
  int? _viewportRows;
  int? _totalRows;

  TerminalSnapshotRow? rowAt(int screenRow) => _rows[screenRow];

  void ingest(TerminalSnapshot snapshot) {
    final incompatible =
        _cols != null &&
        (_cols != snapshot.cols ||
            _viewportRows != snapshot.rows ||
            snapshot.scrollTotalRows < (_totalRows ?? 0));
    if (incompatible || snapshot.alternateScreenActive) clear();
    _cols = snapshot.cols;
    _viewportRows = snapshot.rows;
    _totalRows = snapshot.scrollTotalRows;
    for (var index = 0; index < snapshot.lines.length; index++) {
      _rows[snapshot.viewportOffset + index] = snapshot.lines[index];
    }

    // Keep enough neighboring viewports for direction changes and a fast
    // flick, while bounding decoded row/picture lifetimes.
    final radius = math.max(64, snapshot.rows * 4);
    final minRow = snapshot.viewportOffset - radius;
    final maxRow = snapshot.viewportOffset + snapshot.rows + radius;
    _rows.removeWhere((row, _) => row < minRow || row > maxRow);
  }

  bool covers(double viewportOffset, int visibleRows) {
    if (visibleRows <= 0) return true;
    final range = terminalFractionalViewportRowRange(
      viewportOffset: viewportOffset,
      visibleRows: visibleRows,
      totalRows: _totalRows ?? 0,
    );
    for (var row = range.first; row <= range.last; row++) {
      if (!_rows.containsKey(row)) return false;
    }
    return true;
  }

  /// Picks an integer viewport that will load the first missing visible row.
  int? prefetchOffset({
    required double viewportOffset,
    required int visibleRows,
    required int maxOffset,
  }) {
    if (visibleRows <= 0) return null;
    final range = terminalFractionalViewportRowRange(
      viewportOffset: viewportOffset,
      visibleRows: visibleRows,
      totalRows: _totalRows ?? 0,
    );
    for (var row = range.first; row <= range.last; row++) {
      if (_rows.containsKey(row)) continue;
      // A viewport containing [row] may start anywhere from
      // row-visibleRows+1 through row. Pick the closest valid anchor to the
      // desired viewport. Using `row` directly is correct for a missing top
      // edge but jumps almost a full page for a missing bottom edge.
      final nearestAnchor = viewportOffset.floor().clamp(
        row - visibleRows + 1,
        row,
      );
      return nearestAnchor.clamp(0, math.max(0, maxOffset));
    }
    return null;
  }

  void clear() {
    _rows.clear();
    _cols = null;
    _viewportRows = null;
    _totalRows = null;
  }
}
