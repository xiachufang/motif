import 'dart:async';

typedef RuntimeResourceDisposer<T extends Object> =
    FutureOr<void> Function(T resource);

final class _RuntimeResourceEntry<T extends Object> {
  const _RuntimeResourceEntry(this.resource, this.dispose);

  final T resource;
  final RuntimeResourceDisposer<T> dispose;

  Future<void> close() async => dispose(resource);
}

/// Owns effect-created resources for one runtime-tree node.
///
/// Resources are deliberately not state nodes. Removing a parent node closes
/// its scope after descendant scopes have been closed.
final class RuntimeResourceScope {
  final Map<Object, _RuntimeResourceEntry<Object>> _entries = {};
  bool _closed = false;

  bool get isClosed => _closed;

  T? get<T extends Object>(Object key) {
    final entry = _entries[key];
    final resource = entry?.resource;
    return resource is T ? resource : null;
  }

  Future<void> replace<T extends Object>(
    Object key,
    T resource,
    RuntimeResourceDisposer<T> dispose,
  ) async {
    if (_closed) {
      await dispose(resource);
      return;
    }
    final previous = _entries.remove(key);
    _entries[key] = _RuntimeResourceEntry<Object>(
      resource,
      (value) => dispose(value as T),
    );
    await previous?.close();
  }

  Future<void> remove(Object key) async {
    await _entries.remove(key)?.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final entries = _entries.values.toList().reversed;
    _entries.clear();
    for (final entry in entries) {
      await entry.close();
    }
  }
}
