import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal secret persistence boundary used by app stores.
abstract interface class SecretStore {
  bool get isAvailable;
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain/Keystore/Credential Manager backed implementation.
class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  bool get isAvailable => true;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Safe disabled implementation for tests or capability-limited embedders.
class NoopSecretStore implements SecretStore {
  const NoopSecretStore();

  @override
  bool get isAvailable => false;

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

/// Deterministic test implementation that can be shared across store reloads.
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  bool get isAvailable => true;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
