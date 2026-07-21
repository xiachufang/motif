import 'dart:async';
import 'dart:collection';

import 'runtime_effect.dart';

typedef RuntimeReducer<
  S extends Object,
  E extends Object,
  F extends RuntimeEffect
> = RuntimeTransition<S, F> Function(S state, E event);
typedef RuntimeEffectExecutor<E extends Object, F extends RuntimeEffect> =
    FutureOr<E?> Function(F effect, RuntimeEffectContext context);
typedef RuntimeEffectErrorMapper<E extends Object, F extends RuntimeEffect> =
    E? Function(F effect, Object error, StackTrace stackTrace);
typedef RuntimeTransitionListener<S extends Object, E extends Object> =
    void Function(RuntimeTransitionRecord<S, E> transition);

/// Pure reducer output. Effects start only after [state] has been committed.
final class RuntimeTransition<S extends Object, F extends RuntimeEffect> {
  const RuntimeTransition(
    this.state, {
    this.effects = const [],
    this.invalidateEffects = false,
  });

  final S state;
  final List<F> effects;

  /// Invalidates all outstanding results before starting [effects].
  final bool invalidateEffects;
}

final class RuntimeTransitionRecord<S extends Object, E extends Object> {
  const RuntimeTransitionRecord({
    required this.event,
    required this.previous,
    required this.current,
    required this.scope,
  });

  final E event;
  final S previous;
  final S current;
  final int scope;
}

final class _EffectRun<F extends RuntimeEffect> {
  _EffectRun({required this.effect, required this.context, required this.slot});

  final F effect;
  final RuntimeEffectContext context;
  final _EffectSlot<F>? slot;
}

final class _EffectSlot<F extends RuntimeEffect> {
  _EffectRun<F>? active;
  final Queue<F> serial = Queue<F>();
  F? coalesced;
}

/// Small event/reducer/effect runtime used by each node in the runtime tree.
///
/// Reducers are synchronous. Effect results are accepted only while their
/// token remains current; invalidated Futures may finish, but cannot mutate the
/// machine afterward.
final class RuntimeMachine<
  S extends Object,
  E extends Object,
  F extends RuntimeEffect
> {
  RuntimeMachine({
    required S initialState,
    required this.reducer,
    required this.execute,
    this.mapEffectError,
    this.onTransition,
  }) : _state = initialState;

  S _state;
  final RuntimeReducer<S, E, F> reducer;
  final RuntimeEffectExecutor<E, F> execute;
  final RuntimeEffectErrorMapper<E, F>? mapEffectError;
  final RuntimeTransitionListener<S, E>? onTransition;

  final Queue<E> _events = Queue<E>();
  final Map<Object, _EffectSlot<F>> _slots = {};
  final Set<_EffectRun<F>> _parallel = {};
  bool _reducing = false;
  bool _disposed = false;
  int _scope = 0;
  int _effectSequence = 0;

  S get state => _state;
  int get scope => _scope;
  bool get isDisposed => _disposed;
  int get activeEffectCount =>
      _parallel.length +
      _slots.values.where((slot) => slot.active != null).length;

  void dispatch(E event) {
    if (_disposed) return;
    _events.add(event);
    if (_reducing) return;
    _reducing = true;
    try {
      while (_events.isNotEmpty && !_disposed) {
        final nextEvent = _events.removeFirst();
        final previous = _state;
        final transition = reducer(previous, nextEvent);
        if (transition.invalidateEffects) _invalidateEffects();
        _state = transition.state;
        onTransition?.call(
          RuntimeTransitionRecord(
            event: nextEvent,
            previous: previous,
            current: _state,
            scope: _scope,
          ),
        );
        for (final effect in transition.effects) {
          _submit(effect);
        }
      }
    } finally {
      _reducing = false;
    }
  }

  void invalidateEffects() {
    if (_disposed) return;
    _invalidateEffects();
  }

  void _invalidateEffects() {
    _scope++;
    for (final run in _parallel.toList()) {
      run.context.cancel();
    }
    _parallel.clear();
    for (final slot in _slots.values) {
      slot.active?.context.cancel();
      slot.active = null;
      slot.serial.clear();
      slot.coalesced = null;
    }
    _slots.clear();
  }

  void _submit(F effect) {
    if (_disposed) return;
    switch (effect.mode) {
      case RuntimeEffectMode.parallel:
        _start(effect, null);
      case RuntimeEffectMode.droppable:
        final slot = _slots.putIfAbsent(effect.key, _EffectSlot<F>.new);
        if (slot.active == null) _start(effect, slot);
      case RuntimeEffectMode.restartable:
        final slot = _slots.putIfAbsent(effect.key, _EffectSlot<F>.new);
        slot.active?.context.cancel();
        slot.active = null;
        slot.serial.clear();
        slot.coalesced = null;
        _start(effect, slot);
      case RuntimeEffectMode.serial:
        final slot = _slots.putIfAbsent(effect.key, _EffectSlot<F>.new);
        if (slot.active == null) {
          _start(effect, slot);
        } else {
          slot.serial.add(effect);
        }
      case RuntimeEffectMode.coalescing:
        final slot = _slots.putIfAbsent(effect.key, _EffectSlot<F>.new);
        if (slot.active == null) {
          _start(effect, slot);
        } else {
          slot.coalesced = effect;
        }
    }
  }

  void _start(F effect, _EffectSlot<F>? slot) {
    late final _EffectRun<F> run;
    final token = RuntimeEffectToken(
      scope: _scope,
      sequence: _effectSequence++,
      key: effect.key,
    );
    final context = RuntimeEffectContext(
      token: token,
      current: () => _isCurrent(run),
    );
    run = _EffectRun(effect: effect, context: context, slot: slot);
    if (slot == null) {
      _parallel.add(run);
    } else {
      slot.active = run;
    }

    Future<E?>.sync(() => execute(effect, context)).then(
      (event) => _finish(run, event),
      onError: (Object error, StackTrace stackTrace) {
        final mapped = mapEffectError?.call(effect, error, stackTrace);
        _finish(run, mapped);
      },
    );
  }

  bool _isCurrent(_EffectRun<F> run) {
    if (_disposed || run.context.token.scope != _scope) return false;
    final slot = run.slot;
    return slot == null ? _parallel.contains(run) : identical(slot.active, run);
  }

  void _finish(_EffectRun<F> run, E? event) {
    final current = _isCurrent(run);
    final slot = run.slot;
    if (slot == null) {
      _parallel.remove(run);
    } else if (identical(slot.active, run)) {
      slot.active = null;
    }
    if (!current || _disposed) return;
    if (event != null) dispatch(event);
    if (_disposed || slot == null || slot.active != null) return;

    F? next;
    if (slot.serial.isNotEmpty) {
      next = slot.serial.removeFirst();
    } else {
      next = slot.coalesced;
      slot.coalesced = null;
    }
    if (next != null) {
      _start(next, slot);
    } else if (identical(_slots[run.effect.key], slot)) {
      // Dispatching the result may invalidate the scope and install a fresh
      // slot for the same key. Only the slot that owned [run] may remove
      // itself; otherwise the replacement effect becomes untracked.
      _slots.remove(run.effect.key);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _events.clear();
    _invalidateEffects();
  }
}
