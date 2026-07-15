import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_frame_pacing.dart';

void main() {
  final start = DateTime.utc(2026, 1, 1);

  test('ordinary output uses the lower snapshot rate', () {
    final pacing = TerminalFramePacing();

    expect(
      pacing.intervalForOutput(now: start),
      const Duration(milliseconds: 33),
    );
  });

  test('interaction temporarily boosts output to display cadence', () {
    final pacing = TerminalFramePacing();
    pacing.noteInteraction(at: start);

    expect(
      pacing.intervalForOutput(
        now: start.add(const Duration(milliseconds: 50)),
      ),
      const Duration(milliseconds: 16),
    );
    expect(
      pacing.intervalForOutput(
        now: start.add(const Duration(milliseconds: 201)),
      ),
      const Duration(milliseconds: 33),
    );
  });

  test('viewport movement boosts subsequent output frames', () {
    final pacing = TerminalFramePacing();
    pacing.observeViewportOffset(10, at: start);
    expect(
      pacing.intervalForOutput(now: start),
      const Duration(milliseconds: 33),
    );

    final movedAt = start.add(const Duration(milliseconds: 20));
    pacing.observeViewportOffset(11, at: movedAt);
    expect(
      pacing.intervalForOutput(now: movedAt),
      const Duration(milliseconds: 16),
    );
  });

  test('reset clears interaction and viewport baselines', () {
    final pacing = TerminalFramePacing();
    pacing.observeViewportOffset(10, at: start);
    pacing.observeViewportOffset(11, at: start);
    pacing.reset();

    expect(
      pacing.intervalForOutput(now: start),
      const Duration(milliseconds: 33),
    );
    pacing.observeViewportOffset(20, at: start);
    expect(
      pacing.intervalForOutput(now: start),
      const Duration(milliseconds: 33),
    );
  });
}
