import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_scroll_driver.dart';

void main() {
  test('accumulates logical pixels into terminal rows', () {
    final scroll = TerminalScrollAccumulator();

    expect(scroll.applyPixelDelta(9, 20), 0);
    expect(scroll.applyPixelDelta(11, 20), 1);
    expect(scroll.applyPixelDelta(45, 20), 2);
    expect(scroll.applyPixelDelta(-10, 20), 0);
    expect(scroll.applyPixelDelta(-30, 20), -1);

    scroll.reset();
    expect(scroll.applyPixelDelta(-20, 20), -1);
  });

  test('maps direct touch drag direction to terminal scroll pixels', () {
    expect(touchMoveDeltaToScrollPixels(24), -24);
    expect(touchMoveDeltaToScrollPixels(-18), 18);
    expect(touchMoveDeltaToScrollPixels(0), 0);
  });
}
