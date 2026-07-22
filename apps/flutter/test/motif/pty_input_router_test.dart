import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/workspace/terminal/pty_input_router.dart';
import 'package:motif/motif/terminal/terminal_key.dart';
import 'package:motif/motif/terminal/terminal_session.dart';

void main() {
  test('routes input to the latest surface and ignores stale unregister', () {
    final router = PtyInputRouter();
    final first = <TerminalInputEvent>[];
    final second = <TerminalInputEvent>[];
    bool firstSink(TerminalInputEvent event) {
      first.add(event);
      return true;
    }

    bool secondSink(TerminalInputEvent event) {
      second.add(event);
      return true;
    }

    router.register('pty-1', firstSink);
    router.register('pty-1', secondSink);
    router.unregister('pty-1', firstSink);
    final accepted = router.dispatch(
      'pty-1',
      const TerminalKeyInput(
        keyId: TerminalKeyIds.arrowUp,
        action: TerminalKeyAction.press,
      ),
    );

    expect(accepted, isTrue);
    expect(first, isEmpty);
    expect(second, hasLength(1));
  });

  test('clears one PTY or every registered surface', () {
    final router = PtyInputRouter();
    bool sink(TerminalInputEvent _) => true;
    const input = TerminalKeyInput(
      keyId: TerminalKeyIds.enter,
      action: TerminalKeyAction.press,
    );

    router.register('a', sink);
    router.register('b', sink);
    router.clearPty('a');
    expect(router.dispatch('a', input), isFalse);
    expect(router.dispatch('b', input), isTrue);

    router.clearAll();
    expect(router.dispatch('b', input), isFalse);
  });
}
