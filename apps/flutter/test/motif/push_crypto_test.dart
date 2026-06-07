import 'dart:convert';

import 'package:motif/motif/platform/push_crypto.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// E2E push crypto matches motifd's AES-256-GCM scheme (encrypt→decrypt
/// round-trip in the exact `e=base64(ct‖tag)`, `n=base64(nonce)` wire form).
void main() {
  test('AES-256-GCM push payload round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final key = PushSettingsStore(prefs).encKeyBase64; // 32 random bytes, base64

    const plaintext = '{"title":"Claude","body":"done","session":"dev"}';
    final enc = await encryptPushPayload(
      encKeyB64: key,
      plaintext: utf8.encode(plaintext),
    );
    final back = await decryptPushPayload(encKeyB64: key, eB64: enc.e, nB64: enc.n);
    expect(back, plaintext);
  });

  test('wrong key fails authentication (returns null, not garbage)', () async {
    final enc = await encryptPushPayload(
      encKeyB64: base64Encode(List.filled(32, 1)),
      plaintext: utf8.encode('secret'),
    );
    final back = await decryptPushPayload(
      encKeyB64: base64Encode(List.filled(32, 2)), // different key
      eB64: enc.e,
      nB64: enc.n,
    );
    expect(back, isNull);
  });

  test('nonce is 12 bytes and tag is appended (server wire form)', () async {
    final enc = await encryptPushPayload(
      encKeyB64: base64Encode(List.filled(32, 7)),
      plaintext: utf8.encode('hi'),
    );
    expect(base64Decode(enc.n).length, 12);
    // ciphertext (2 bytes for "hi") + 16-byte GCM tag.
    expect(base64Decode(enc.e).length, 2 + 16);
  });
}
