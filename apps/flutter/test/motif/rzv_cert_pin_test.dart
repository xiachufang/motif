import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/proxy_client.dart';

/// The rzv cert-pinning path: `makeHttpClient(certPin: ...)` must accept exactly
/// the server whose leaf cert hashes to the pin (mirrors how the Dart client
/// pins motifd through the loopback forwarder), and reject any other cert.
void main() {
  late HttpServer server;

  setUp(() async {
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_certPem))
      ..usePrivateKeyBytes(utf8.encode(_keyPem));
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..write('ok');
      req.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  final goodPin =
      Uint8List.fromList(sha256.convert(base64.decode(_certDerB64)).bytes);

  test('accepts the pinned cert over a real TLS handshake', () async {
    final client = makeHttpClient(ProxySettings.none, certPin: goodPin);
    final resp =
        await client.get(Uri.parse('https://127.0.0.1:${server.port}/'));
    expect(resp.statusCode, 200);
    expect(resp.body, 'ok');
    client.close();
  });

  test('rejects a mismatched pin', () async {
    final wrong = Uint8List.fromList(goodPin);
    wrong[0] ^= 0xff;
    final client = makeHttpClient(ProxySettings.none, certPin: wrong);
    await expectLater(
      client.get(Uri.parse('https://127.0.0.1:${server.port}/')),
      throwsA(isA<HandshakeException>()),
    );
    client.close();
  });
}

const _certPem = '''
-----BEGIN CERTIFICATE-----
MIIBGDCBvgIJAN3cKs11oLe8MAoGCCqGSM49BAMCMBQxEjAQBgNVBAMMCW1vdGlm
LXJ6djAeFw0yNjA2MTQwMjAyMTdaFw0zNjA2MTEwMjAyMTdaMBQxEjAQBgNVBAMM
CW1vdGlmLXJ6djBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLnr4uPTJuGzjFkr
lpMXEw72hbT+hl2vzRl5kpbGrboCWZFkPULEPI7Iybbblej3eiWnyxEto8ECoA/7
TwcyLq4wCgYIKoZIzj0EAwIDSQAwRgIhAJ49Kv+WGepl6xRkUkD5rtt3LninNhil
I4uoajUuGocyAiEAkbyhMYabjUmYNk2jzBu9LFnXb1PaljrFckXqRksw1do=
-----END CERTIFICATE-----
''';

const _keyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgLb4jGWtyrLJ/hy55
LsPL6WemFjte/4Vtq6xmQMhaFHmhRANCAAS56+Lj0ybhs4xZK5aTFxMO9oW0/oZd
r80ZeZKWxq26AlmRZD1CxDyOyMm225Xo93olp8sRLaPBAqAP+08HMi6u
-----END PRIVATE KEY-----
''';

/// DER of the cert above, base64 — hashed to derive the expected pin.
const _certDerB64 =
    'MIIBGDCBvgIJAN3cKs11oLe8MAoGCCqGSM49BAMCMBQxEjAQBgNVBAMMCW1vdGlmLXJ6djAeFw0yNjA2MTQwMjAyMTdaFw0zNjA2MTEwMjAyMTdaMBQxEjAQBgNVBAMMCW1vdGlmLXJ6djBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLnr4uPTJuGzjFkrlpMXEw72hbT+hl2vzRl5kpbGrboCWZFkPULEPI7Iybbblej3eiWnyxEto8ECoA/7TwcyLq4wCgYIKoZIzj0EAwIDSQAwRgIhAJ49Kv+WGepl6xRkUkD5rtt3LninNhilI4uoajUuGocyAiEAkbyhMYabjUmYNk2jzBu9LFnXb1PaljrFckXqRksw1do=';
