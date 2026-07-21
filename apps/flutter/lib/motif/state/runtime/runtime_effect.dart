import 'dart:async';

/// Concurrency semantics for one keyed runtime effect.
enum RuntimeEffectMode {
  /// Run every effect independently.
  parallel,

  /// Ignore a new effect while an effect with the same key is running.
  droppable,

  /// Logically cancel the running effect and accept only the newest result.
  restartable,

  /// Run effects with the same key in submission order.
  serial,

  /// While one effect is running, retain only the newest pending effect.
  coalescing,
}

/// Metadata required by [RuntimeMachine] to coordinate asynchronous work.
abstract interface class RuntimeEffect {
  Object get key;
  RuntimeEffectMode get mode;
}

/// Identity of one effect execution inside a machine scope.
final class RuntimeEffectToken {
  const RuntimeEffectToken({
    required this.scope,
    required this.sequence,
    required this.key,
  });

  final int scope;
  final int sequence;
  final Object key;

  @override
  String toString() => 'effect[$scope:$sequence:$key]';
}

/// Cooperative cancellation and identity exposed to an effect executor.
final class RuntimeEffectContext {
  RuntimeEffectContext({required this.token, required this.current});

  final RuntimeEffectToken token;
  final bool Function() current;
  final Completer<void> _cancelled = Completer<void>();

  bool get isCurrent => current();
  Future<void> get cancelled => _cancelled.future;

  /// Waits without leaving an uncancellable [Timer] behind after this effect
  /// is superseded or its node is disposed. Returns whether the full delay
  /// elapsed while the effect was still current.
  Future<bool> delay(Duration duration) {
    if (duration <= Duration.zero) return Future<bool>.value(isCurrent);
    final completer = Completer<bool>();
    late final Timer timer;
    timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete(isCurrent);
    });
    cancelled.then((_) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete(false);
    });
    return completer.future;
  }

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
