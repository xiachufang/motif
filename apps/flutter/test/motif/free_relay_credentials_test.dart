import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motif/motif/platform/secret_store.dart';
import 'package:motif/motif/state/embedded/free_relay_credentials.dart';

void main() {
  test(
    'registers an installation and stores both tokens as one secret',
    () async {
      final secrets = MemorySecretStore();
      final requests = <http.Request>[];
      final manager = FreeRelayCredentialManager(
        secrets,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(_credentials(access: 'access-1', refresh: 'refresh-1')),
            201,
          );
        }),
        now: () =>
            DateTime.fromMillisecondsSinceEpoch(1000 * 1000, isUtc: true),
      );

      final credentials = await manager.ensureValid('relay.example.com');

      expect(
        requests.single.url.toString(),
        'https://relay.example.com/v1/free/installations',
      );
      expect(credentials.installationId, 'inst_test');
      expect(credentials.accessToken, 'access-1');
      expect(
        secrets.values[kEmbeddedFreeRelayCredentialsSecretKey],
        contains('refresh-1'),
      );
    },
  );

  test('refreshes near expiry and rotates the refresh token', () async {
    final secrets = MemorySecretStore();
    await secrets.write(
      kEmbeddedFreeRelayCredentialsSecretKey,
      jsonEncode(
        _credentials(
          access: 'old-access',
          refresh: 'old-refresh',
          accessExpiresAt: 1001,
        ),
      ),
    );
    final manager = FreeRelayCredentialManager(
      secrets,
      client: MockClient((request) async {
        expect(request.url.path, '/v1/free/token');
        expect(request.headers['authorization'], 'Bearer old-refresh');
        return http.Response(
          jsonEncode(
            _credentials(access: 'new-access', refresh: 'new-refresh'),
          ),
          200,
        );
      }),
      now: () => DateTime.fromMillisecondsSinceEpoch(1000 * 1000, isUtc: true),
    );

    final credentials = await manager.ensureValid('https://relay.example.com');

    expect(credentials.accessToken, 'new-access');
    expect(credentials.refreshToken, 'new-refresh');
  });

  test(
    'keeps a valid access token during a transient refresh failure',
    () async {
      final secrets = MemorySecretStore();
      await secrets.write(
        kEmbeddedFreeRelayCredentialsSecretKey,
        jsonEncode(
          _credentials(
            access: 'still-valid',
            refresh: 'refresh',
            accessExpiresAt: 1100,
          ),
        ),
      );
      final manager = FreeRelayCredentialManager(
        secrets,
        client: MockClient((_) async => throw Exception('offline')),
        now: () =>
            DateTime.fromMillisecondsSinceEpoch(1000 * 1000, isUtc: true),
      );

      final credentials = await manager.ensureValid('relay.example.com');

      expect(credentials.accessToken, 'still-valid');
    },
  );

  test('forced refresh surfaces an outage so the caller can retry', () async {
    final secrets = MemorySecretStore();
    await secrets.write(
      kEmbeddedFreeRelayCredentialsSecretKey,
      jsonEncode(
        _credentials(
          access: 'rejected-access',
          refresh: 'refresh',
          accessExpiresAt: 200000,
        ),
      ),
    );
    final manager = FreeRelayCredentialManager(
      secrets,
      client: MockClient((_) async => throw Exception('offline')),
      now: () => DateTime.fromMillisecondsSinceEpoch(1000 * 1000, isUtc: true),
    );

    await expectLater(
      manager.ensureValid('relay.example.com', forceRefresh: true),
      throwsException,
    );
  });
}

Map<String, Object?> _credentials({
  required String access,
  required String refresh,
  int accessExpiresAt = 200000,
}) => {
  'installation_id': 'inst_test',
  'access_token': access,
  'access_expires_at': accessExpiresAt,
  'refresh_token': refresh,
  'refresh_expires_at': 400000,
};
