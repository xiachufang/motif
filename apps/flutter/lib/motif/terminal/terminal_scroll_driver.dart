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
