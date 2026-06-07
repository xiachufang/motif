import 'dart:convert';

import 'package:motif/motif/state/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('generates a persistent 256-bit AES key', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final s1 = PushSettingsStore(prefs);
    expect(base64Decode(s1.encKeyBase64).length, 32);
    // Same prefs → same key (persisted, not regenerated).
    final s2 = PushSettingsStore(prefs);
    expect(s2.encKeyBase64, s1.encKeyBase64);
  });

  test('mute set persists and round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final s = PushSettingsStore(prefs);
    expect(s.enabled, isTrue);
    expect(s.isMuted('work'), isFalse);
    await s.setMuted('work', true);
    expect(s.isMuted('work'), isTrue);

    final reloaded = PushSettingsStore(prefs);
    expect(reloaded.isMuted('work'), isTrue);

    await s.setEnabled(false);
    expect(PushSettingsStore(prefs).enabled, isFalse);
  });
}
