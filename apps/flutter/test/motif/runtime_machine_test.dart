import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/runtime/runtime_effect.dart';
import 'package:motif/motif/state/runtime/runtime_machine.dart';
import 'package:motif/motif/state/runtime/runtime_resource_scope.dart';

sealed class _Event {
  const _Event();
}

final class _Start extends _Event {
  const _Start(this.value, this.mode);

  final int value;
  final RuntimeEffectMode mode;
}

final class _Completed extends _Event {
  const _Completed(this.value);

  final int value;
}

final class _Invalidate extends _Event {
  const _Invalidate();
}

final class _Replace extends _Event {
  const _Replace();
}

final class _Effect implements RuntimeEffect {
  const _Effect(this.value, this.mode);

  final int value;
  @override
  final RuntimeEffectMode mode;

  @override
  Object get key => 'work';
}

RuntimeTransition<int, _Effect> _reduce(int state, _Event event) {
  return switch (event) {
    _Start(:final value, :final mode) => RuntimeTransition(
      state,
      effects: [_Effect(value, mode)],
    ),
    _Completed(:final value) => RuntimeTransition(value),
    _Invalidate() => RuntimeTransition(state, invalidateEffects: true),
    _Replace() => RuntimeTransition(
      state,
      invalidateEffects: true,
      effects: const [_Effect(2, RuntimeEffectMode.restartable)],
    ),
  };
}

void main() {
  test('restartable accepts only the newest effect result', () async {
    final completions = <int, Completer<_Event?>>{};
    final machine = RuntimeMachine<int, _Event, _Effect>(
      initialState: 0,
      reducer: _reduce,
      execute: (effect, _) =>
          (completions[effect.value] = Completer<_Event?>()).future,
    );
    addTearDown(machine.dispose);

    machine
      ..dispatch(const _Start(1, RuntimeEffectMode.restartable))
      ..dispatch(const _Start(2, RuntimeEffectMode.restartable));
    await Future<void>.delayed(Duration.zero);

    completions[1]!.complete(const _Completed(1));
    await Future<void>.delayed(Duration.zero);
    expect(machine.state, 0);

    completions[2]!.complete(const _Completed(2));
    await Future<void>.delayed(Duration.zero);
    expect(machine.state, 2);
  });

  test('coalescing retains only the newest pending effect', () async {
    final started = <int>[];
    final completions = <int, Completer<_Event?>>{};
    final machine = RuntimeMachine<int, _Event, _Effect>(
      initialState: 0,
      reducer: _reduce,
      execute: (effect, _) {
        started.add(effect.value);
        return (completions[effect.value] = Completer<_Event?>()).future;
      },
    );
    addTearDown(machine.dispose);

    machine
      ..dispatch(const _Start(1, RuntimeEffectMode.coalescing))
      ..dispatch(const _Start(2, RuntimeEffectMode.coalescing))
      ..dispatch(const _Start(3, RuntimeEffectMode.coalescing));
    await Future<void>.delayed(Duration.zero);
    expect(started, [1]);

    completions[1]!.complete(const _Completed(1));
    await Future<void>.delayed(Duration.zero);
    expect(started, [1, 3]);

    completions[3]!.complete(const _Completed(3));
    await Future<void>.delayed(Duration.zero);
    expect(machine.state, 3);
  });

  test('invalidating the scope rejects an old completion', () async {
    final completion = Completer<_Event?>();
    final machine = RuntimeMachine<int, _Event, _Effect>(
      initialState: 0,
      reducer: _reduce,
      execute: (_, _) => completion.future,
    );
    addTearDown(machine.dispose);

    machine
      ..dispatch(const _Start(1, RuntimeEffectMode.parallel))
      ..dispatch(const _Invalidate());
    completion.complete(const _Completed(1));
    await Future<void>.delayed(Duration.zero);

    expect(machine.state, 0);
    expect(machine.activeEffectCount, 0);
  });

  test('result transition cannot remove its replacement effect slot', () async {
    final started = <int>[];
    final completions = <int, Completer<_Event?>>{};
    final machine = RuntimeMachine<int, _Event, _Effect>(
      initialState: 0,
      reducer: _reduce,
      execute: (effect, _) {
        started.add(effect.value);
        if (effect.value == 1) return const _Replace();
        return (completions[effect.value] = Completer<_Event?>()).future;
      },
    );
    addTearDown(machine.dispose);

    machine.dispatch(const _Start(1, RuntimeEffectMode.restartable));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(started, [1, 2]);
    expect(machine.activeEffectCount, 1);

    machine.dispatch(const _Start(3, RuntimeEffectMode.restartable));
    await Future<void>.delayed(Duration.zero);
    completions[3]!.complete(const _Completed(3));
    await Future<void>.delayed(Duration.zero);
    expect(machine.state, 3);

    completions[2]!.complete(const _Completed(2));
    await Future<void>.delayed(Duration.zero);
    expect(machine.state, 3);
  });

  test('resource scope replaces and closes resources exactly once', () async {
    final closed = <String>[];
    final scope = RuntimeResourceScope();

    await scope.replace('rpc', 'first', (value) => closed.add(value));
    await scope.replace('rpc', 'second', (value) => closed.add(value));
    expect(closed, ['first']);
    expect(scope.get<String>('rpc'), 'second');

    await scope.close();
    await scope.close();
    expect(closed, ['first', 'second']);
  });
}
