/// End-to-end push payload crypto, matching `motifd`'s scheme
/// (`crates/motif-server/src/relay.rs`): **AES-256-GCM**, fresh 12-byte nonce,
/// wire form `e = base64(ciphertext‖16-byte tag)`, `n = base64(nonce)`, key is
/// base64 of 32 raw bytes (the per-device key in `PushSettingsStore`).
///
/// The on-device decryption normally happens in the iOS Notification Service
/// Extension (CryptoKit), but the same logic runs here so foreground
/// notifications can be decrypted in-app and so the format is unit-testable
/// without a device. No Firebase involved.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _aesGcm = AesGcm.with256bits();

/// Decrypt an E2E push payload. Returns the plaintext (the notification JSON),
/// or null if the key/inputs are malformed or authentication fails.
Future<String?> decryptPushPayload({
  required String encKeyB64,
  required String eB64,
  required String nB64,
}) async {
  try {
    final key = base64Decode(encKeyB64);
    final eAndTag = base64Decode(eB64);
    final nonce = base64Decode(nB64);
    if (key.length != 32 || eAndTag.length < 16) return null;
    final cipherText = eAndTag.sublist(0, eAndTag.length - 16);
    final tag = eAndTag.sublist(eAndTag.length - 16);
    final clear = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
      secretKey: SecretKey(key),
    );
    return utf8.decode(clear);
  } catch (_) {
    return null;
  }
}

/// Encrypt a payload in the same wire form (`(e, n)`). Used by tests and any
/// in-app path that needs to produce server-compatible ciphertext.
Future<({String e, String n})> encryptPushPayload({
  required String encKeyB64,
  required List<int> plaintext,
}) async {
  final box = await _aesGcm.encrypt(
    plaintext,
    secretKey: SecretKey(base64Decode(encKeyB64)),
  );
  final eAndTag = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setRange(0, box.cipherText.length, box.cipherText)
    ..setRange(
      box.cipherText.length,
      box.cipherText.length + box.mac.bytes.length,
      box.mac.bytes,
    );
  return (e: base64Encode(eAndTag), n: base64Encode(box.nonce));
}
