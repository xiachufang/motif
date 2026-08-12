import 'package:shared_preferences/shared_preferences.dart';

/// Minimal secret persistence boundary used by app stores.
abstract interface class SecretStore {
  bool get isAvailable;
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Preferences-backed secret persistence.
///
/// Values are namespaced but are not encrypted at rest. The prefix is retained
/// for compatibility with builds that previously used preferences as a
/// fallback when the primary persistence backend was unavailable.
class PreferencesSecretStore implements SecretStore {
  PreferencesSecretStore({Future<SharedPreferences>? preferences})
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

/// Reads from [primary], falling back to [legacy] once and moving any value it
/// finds into [primary]. Successful writes and deletes also clear [legacy].
class MigratingSecretStore implements SecretStore {
  const MigratingSecretStore({required this.primary, required this.legacy});

  final SecretStore primary;
  final SecretStore legacy;

  @override
  bool get isAvailable => primary.isAvailable;

  @override
  Future<String?> read(String key) async {
    final value = await primary.read(key);
    if (value != null) return value;

    final legacyValue = await legacy.read(key);
    if (legacyValue == null) return null;

    await primary.write(key, legacyValue);
    await legacy.delete(key);
    return legacyValue;
  }

  @override
  Future<void> write(String key, String value) async {
    await primary.write(key, value);
    await legacy.delete(key);
  }

  @override
  Future<void> delete(String key) async {
    await primary.delete(key);
    await legacy.delete(key);
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
