import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Temporary plaintext fallback for platforms that cannot use their secure
/// store. Values are namespaced but are NOT encrypted at rest.
///
/// macOS uses this until releases are signed with Developer ID Application;
/// switch the macOS factory back to [FlutterSecureSecretStore] once that
/// certificate is available.
class PlaintextPreferencesSecretStore implements SecretStore {
  PlaintextPreferencesSecretStore({Future<SharedPreferences>? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance();

  static const _prefix = 'motif.insecureSecret.';
  final Future<SharedPreferences> _preferences;

  @override
  bool get isAvailable => true;

  @override
  Future<String?> read(String key) async {
    final preferences = await _preferences;
    return preferences.getString('$_prefix$key');
  }

  @override
  Future<void> write(String key, String value) async {
    final preferences = await _preferences;
    await preferences.setString('$_prefix$key', value);
  }

  @override
  Future<void> delete(String key) async {
    final preferences = await _preferences;
    await preferences.remove('$_prefix$key');
  }
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
