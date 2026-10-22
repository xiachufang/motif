import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/web_link.dart';

void main() {
  test('IP literals and localhost use the originating server', () {
    for (final value in [
      'http://127.0.0.1:3000/a',
      'http://127.0.0.2:3000/a',
      'http://192.168.1.8/',
      'https://8.8.8.8/',
      'http://[::1]:8080/',
      'https://[2001:db8::1]/',
      'http://localhost:5173/',
      'http://LOCALHOST:5173/',
    ]) {
      final uri = parseWebLink(value);
      expect(uri, isNotNull, reason: value);
      expect(webLinkNeedsServerProxy(uri!), isTrue, reason: value);
    }
    for (final value in [
      'https://example.com',
      'http://127.0.0.1.example.com',
      'http://localhost.example.com',
      'https://example.com/?url=http://127.0.0.1:3000',
    ]) {
      expect(
        webLinkNeedsServerProxy(parseWebLink(value)!),
        isFalse,
        reason: value,
      );
    }
  });

  test('proxy preserves scheme, encoded path, query and fragment', () {
    final url = Uri.parse('https://[::1]:8443/a%2Fb?q=x%26y&q=z#section-2');
    final local = Uri.parse('https://127.0.0.1:49152/');
    final result = proxiedWebLink(url, local);
    expect(
      result.toString(),
      'https://127.0.0.1:49152/a%2Fb?q=x%26y&q=z#section-2',
    );
    expect(parseWebLink('http://192.168.1.8/')!.port, 80);
    expect(parseWebLink('https://192.168.1.8/')!.port, 443);
  });

  test('invalid and non-web targets are rejected before opening', () {
    for (final value in [
      'file:///tmp/test',
      'javascript:alert(1)',
      'https:///missing-host',
      'https://example.com:0',
      'https://example.com:65536',
      'https://user:pass@example.com',
      ' https://example.com',
      'https://example.com/a b',
      'https://example.com/\u0007',
    ]) {
      expect(parseWebLink(value), isNull, reason: value);
    }
  });
}
