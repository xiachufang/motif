import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/web_link.dart';

void main() {
  test('accepts http and https OSC 8 destinations', () {
    expect(
      parseWebLink('https://example.com/docs?q=osc8'),
      Uri.parse('https://example.com/docs?q=osc8'),
    );
    expect(
      parseWebLink('http://127.0.0.1:8080/'),
      Uri.parse('http://127.0.0.1:8080/'),
    );
  });

  test(
    'rejects local, custom, malformed, and control-bearing destinations',
    () {
      for (final value in [
        'file:///tmp/report.html',
        'vscode://file/tmp/main.dart:10',
        'javascript:alert(1)',
        'https:///missing-host',
        ' https://example.com',
        'https://example.com\u0007',
      ]) {
        expect(parseWebLink(value), isNull, reason: value);
      }
    },
  );
}
