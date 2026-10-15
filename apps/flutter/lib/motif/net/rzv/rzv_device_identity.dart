import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// An installation-scoped diagnostic ID, unrelated to pairing credentials.
/// Reinstalling/clearing application data creates a new ID.
class RzvDeviceIdentity {
  static const preferenceKey = 'motif.rzv.diagnostic_device_id';
  static Future<String>? _pending;

  // Serialize concurrent first use so all forwarders get the same persisted ID.
  static Future<String> load() => _pending ??= _load().whenComplete(() {
    _pending = null;
  });

  static Future<String> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(preferenceKey);
    if (existing != null && RegExp(r'^app_[0-9a-f]{32}$').hasMatch(existing)) {
      return existing;
    }
    final random = Random.secure();
    final id =
        'app_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    if (!await prefs.setString(preferenceKey, id)) {
      throw StateError('Could not persist relay diagnostic device ID');
    }
    return id;
  }
}
