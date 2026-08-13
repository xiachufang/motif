import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

/// The distance from the bottom that still counts as following live output.
const double terminalAutoFollowThresholdRows = 1;
const double _terminalScrollExtentTolerance = 1e-10;

bool terminalScrollPositionIsNearBottom({
  required double pixels,
  required double maxScrollExtent,
  required double thresholdPixels,
}) {
  final threshold = thresholdPixels > 0 ? thresholdPixels : 0;
  return pixels >= maxScrollExtent - threshold - _terminalScrollExtentTolerance;
}

typedef TerminalViewportTarget = ({int offset, bool latest});

/// One projection of Flutter's pixel position into Ghostty and paint space.
class TerminalViewportProjection {
  final double visualRowOffset;
  final int rowAnchor;
  final double pixelRemainder;
  final double paintOffset;
  final TerminalViewportTarget target;

  const TerminalViewportProjection._({
    required this.visualRowOffset,
    required this.rowAnchor,
    required this.pixelRemainder,
    required this.paintOffset,
    required this.target,
  });

  factory TerminalViewportProjection.calculate({
    required double scrollPixels,
    required double rowHeight,
    required int maxViewportOffset,
    required double maxScrollPixels,
    required int snapshotViewportOffset,
    required bool snapshotIsLive,
    required bool followsLatest,
  }) {
    final mapped = terminalViewportPositionFromScrollPixels(
      scrollPixels: scrollPixels,
      maxOffset: maxViewportOffset,
      rowHeight: rowHeight,
    );
    final liveElasticOffset = scrollPixels - maxScrollPixels;
    final paintOffset = snapshotIsLive && followsLatest
        ? (liveElasticOffset > 0 ? liveElasticOffset : 0)
        : scrollPixels - snapshotViewportOffset * rowHeight;
    return TerminalViewportProjection._(
      visualRowOffset: rowHeight > 0 ? scrollPixels / rowHeight : 0,
      rowAnchor: mapped.viewportOffset,
      pixelRemainder: mapped.pixelRemainder,
      paintOffset: paintOffset.toDouble(),
      target: followsLatest
          ? (offset: maxViewportOffset, latest: true)
          : (offset: mapped.viewportOffset, latest: false),
    );
  }
}

double? terminalFollowCorrectionForNewDimensions({
  required bool followsLatest,
  required double oldPixels,
  required double oldMaxScrollExtent,
  required double newPixels,
  required double newMaxScrollExtent,
}) {
  if (!followsLatest ||
      (newMaxScrollExtent - oldMaxScrollExtent).abs() <=
          _terminalScrollExtentTolerance ||
      newPixels < oldPixels - _terminalScrollExtentTolerance) {
    return null;
  }
  final elasticDisplacement = oldPixels - oldMaxScrollExtent;
  return newMaxScrollExtent +
      (elasticDisplacement > 0 ? elasticDisplacement : 0);
}

/// Uses Flutter's platform physics while allowing pointer-signal devices to
/// enter the elastic range. Flutter's default pointerScroll clamps wheel and
/// Magic Mouse events before [BouncingScrollPhysics] can see the overscroll.
class TerminalScrollController extends ScrollController {
  TerminalScrollController({super.debugLabel, super.keepScrollOffset = false});

  double autoFollowThresholdPixels = 0;
  bool _initialFollowsLatest = true;

  TerminalScrollPosition get terminalPosition =>
      position as TerminalScrollPosition;

  bool get followsLatest =>
      hasClients ? terminalPosition.followsLatest : _initialFollowsLatest;

  void followLatest() {
    _initialFollowsLatest = true;
    if (hasClients) terminalPosition.followLatest();
  }

  void resetAutoFollow() => followLatest();

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    final followsLatest = oldPosition is TerminalScrollPosition
        ? oldPosition.followsLatest
        : _initialFollowsLatest;
    return TerminalScrollPosition(
      physics: physics,
      context: context,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      initialFollowsLatest: followsLatest,
      autoFollowThreshold: () => autoFollowThresholdPixels,
    );
  }
}

class TerminalScrollPosition extends ScrollPositionWithSingleContext {
  bool _followsLatest;
  final double Function() autoFollowThreshold;

  TerminalScrollPosition({
    required super.physics,
    required super.context,
    required super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
    required bool initialFollowsLatest,
    required this.autoFollowThreshold,
  }) : _followsLatest = initialFollowsLatest;

  bool get followsLatest => _followsLatest;

  void followLatest() => _followsLatest = true;

  void _updateAutoFollowIntent(double delta) {
    if (!hasContentDimensions) return;
    if (delta < -_terminalScrollExtentTolerance &&
        pixels < maxScrollExtent - _terminalScrollExtentTolerance) {
      _followsLatest = false;
    } else if (!_followsLatest &&
        delta > _terminalScrollExtentTolerance &&
        terminalScrollPositionIsNearBottom(
          pixels: pixels,
          maxScrollExtent: maxScrollExtent,
          thresholdPixels: autoFollowThreshold(),
        )) {
      _followsLatest = true;
    }
  }

  @override
  double setPixels(double newPixels) {
    final oldPixels = pixels;
    final overscroll = super.setPixels(newPixels);
    _updateAutoFollowIntent(pixels - oldPixels);
    return overscroll;
  }

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    final correction = terminalFollowCorrectionForNewDimensions(
      followsLatest: _followsLatest,
      oldPixels: oldPosition.pixels,
      oldMaxScrollExtent: oldPosition.maxScrollExtent,
      newPixels: newPosition.pixels,
      newMaxScrollExtent: newPosition.maxScrollExtent,
    );
    if (correction == null) {
      return super.correctForNewDimensions(oldPosition, newPosition);
    }
    if ((correction - pixels).abs() <= _terminalScrollExtentTolerance) {
      return true;
    }
    correctPixels(correction);
    return false;
  }

  @override
  void pointerScroll(double delta) {
    if (delta == 0) {
      goBallistic(0);
      return;
    }
    final appliedDelta = outOfRange
        ? physics.applyPhysicsToUserOffset(this, delta)
        : delta;
    final candidatePixels = pixels + appliedDelta;
    final boundary = physics.applyBoundaryConditions(this, candidatePixels);
    final targetPixels = candidatePixels - boundary;
    if (targetPixels == pixels) return;

    goIdle();
    updateUserScrollDirection(
      delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    final oldPixels = pixels;
    isScrollingNotifier.value = true;
    forcePixels(targetPixels);
    _updateAutoFollowIntent(pixels - oldPixels);
    didStartScroll();
    didUpdateScrollPositionBy(pixels - oldPixels);
    didEndScroll();
    goBallistic(0);
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

/// Splits Flutter's continuous scroll position into a Ghostty row anchor and
/// the remaining client-side pixel translation.
///
/// The anchor is `floor(topRow)`. Ghostty always returns fixed vertical
/// overscan, so its bottom extra row supplies `ceil(bottomRow)` whenever the
/// remainder is non-zero; Flutter paints all returned rows and clips them.
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
