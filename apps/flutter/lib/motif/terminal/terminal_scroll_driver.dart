import 'package:flutter/widgets.dart';

/// Keeps the live terminal area pinned while a forward scroll extent grows.
///
/// Flutter and Ghostty now share the same coordinate system: pixel/row zero is
/// the oldest scrollback and the maximum extent is the active terminal area.
/// A viewport in history therefore keeps its existing pixels when new output
/// arrives. Only a viewport already following the bottom moves with the new
/// maximum, preserving any drag or ballistic delta applied in the same frame.
class TerminalScrollAnchorPhysics extends ScrollPhysics {
  static const double _extentTolerance = 1e-10;
  final bool followLatest;

  const TerminalScrollAnchorPhysics({this.followLatest = true, super.parent});

  @override
  TerminalScrollAnchorPhysics applyTo(ScrollPhysics? ancestor) {
    return TerminalScrollAnchorPhysics(
      followLatest: followLatest,
      parent: buildParent(ancestor),
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final fallback = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    final maxExtentDelta =
        newPosition.maxScrollExtent - oldPosition.maxScrollExtent;
    if (!followLatest || maxExtentDelta.abs() <= _extentTolerance) {
      return fallback;
    }

    final wasFollowingLatest =
        oldPosition.pixels >= oldPosition.maxScrollExtent - _extentTolerance;
    if (!wasFollowingLatest) return fallback;

    return newPosition.maxScrollExtent +
        (newPosition.pixels - oldPosition.maxScrollExtent);
  }
}

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

/// Ghostty's default multiplier for a discrete mouse-wheel tick.
int terminalRowsFromDiscreteWheel(double deltaY, {int rowsPerTick = 3}) {
  if (deltaY == 0 || rowsPerTick <= 0) return 0;
  return deltaY.isNegative ? -rowsPerTick : rowsPerTick;
}

/// Maps Ghostty's absolute row offset onto Flutter's matching forward axis.
double terminalScrollPixelsFromViewportOffset({
  required int viewportOffset,
  required double rowHeight,
}) {
  if (rowHeight <= 0 || viewportOffset <= 0) return 0;
  return viewportOffset * rowHeight;
}

/// Splits Flutter's continuous scroll position into a Ghostty row anchor and
/// the remaining client-side pixel translation.
({int viewportOffset, double pixelRemainder})
terminalViewportPositionFromScrollPixels({
  required double scrollPixels,
  required int maxOffset,
  required double rowHeight,
}) {
  if (rowHeight <= 0 || maxOffset <= 0) {
    return (viewportOffset: 0, pixelRemainder: 0);
  }
  final maxPixels = maxOffset * rowHeight;
  final pixels = scrollPixels.clamp(0.0, maxPixels).toDouble();
  if (pixels >= maxPixels) {
    return (viewportOffset: maxOffset, pixelRemainder: 0);
  }
  final viewportOffset = (pixels / rowHeight).floor();
  return (
    viewportOffset: viewportOffset,
    pixelRemainder: pixels - viewportOffset * rowHeight,
  );
}

/// Maps Flutter pixels to the Ghostty row anchoring that pixel viewport.
int terminalViewportOffsetFromScrollPixels({
  required double scrollPixels,
  required int maxOffset,
  required double rowHeight,
}) {
  return terminalViewportPositionFromScrollPixels(
    scrollPixels: scrollPixels,
    maxOffset: maxOffset,
    rowHeight: rowHeight,
  ).viewportOffset;
}
