/// Automatic anonymous credentials for Motif's public Free Relay.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../platform/secret_store.dart';

const String kEmbeddedFreeRelayCredentialsSecretKey =
    'motif.embedded.rzv.free.credentials';

const Duration kFreeRelayRefreshBeforeExpiry = Duration(hours: 24);

class FreeRelayCredentials {
  final String installationId;
  final String accessToken;
  final int accessExpiresAt;
  final String refreshToken;
  final int refreshExpiresAt;

  const FreeRelayCredentials({
    required this.installationId,
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
    required this.refreshExpiresAt,
  });

  factory FreeRelayCredentials.fromJson(Map<String, Object?> json) {
    String string(String key) =>
        json[key] is String ? json[key]! as String : '';
    int integer(String key) =>
        json[key] is num ? (json[key]! as num).toInt() : 0;
    return FreeRelayCredentials(
      installationId: string('installation_id'),
      accessToken: string('access_token'),
      accessExpiresAt: integer('access_expires_at'),
      refreshToken: string('refresh_token'),
      refreshExpiresAt: integer('refresh_expires_at'),
    );
  }

  Map<String, Object?> toJson() => {
    'installation_id': installationId,
    'access_token': accessToken,
    'access_expires_at': accessExpiresAt,
    'refresh_token': refreshToken,
    'refresh_expires_at': refreshExpiresAt,
  };

  bool get isComplete =>
      installationId.isNotEmpty &&
      accessToken.isNotEmpty &&
      accessExpiresAt > 0 &&
      refreshToken.isNotEmpty &&
      refreshExpiresAt > 0;
}

class FreeRelayCredentialManager {
  FreeRelayCredentialManager(
    this._secrets, {
    http.Client? client,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _now = now ?? DateTime.now;

  final SecretStore _secrets;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;

  Future<FreeRelayCredentials> ensureValid(
    String relay, {
    bool forceRefresh = false,
  }) async {
    if (!_secrets.isAvailable) {
      throw StateError('Secret storage is required for Free Relay.');
    }
    final saved = await _load();
    final now = _now().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (!forceRefresh &&
        saved != null &&
        saved.accessExpiresAt - now > kFreeRelayRefreshBeforeExpiry.inSeconds) {
      return saved;
    }

    if (saved != null && saved.refreshExpiresAt > now) {
      try {
        return await _refresh(relay, saved.refreshToken);
      } on FreeRelayUnauthorizedException {
        // The stateless refresh credential expired or no longer validates;
        // get a new anonymous installation below.
      } catch (_) {
        // Keep a still-valid access token during a transient outage.
        if (!forceRefresh && saved.accessExpiresAt > now) return saved;
        rethrow;
      }
    }
    return _register(relay);
  }

  Future<FreeRelayCredentials?> _load() async {
    final raw = await _secrets.read(kEmbeddedFreeRelayCredentialsSecretKey);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final credentials = FreeRelayCredentials.fromJson(
        value.cast<String, Object?>(),
      );
      return credentials.isComplete ? credentials : null;
    } catch (_) {
      return null;
    }
  }

  Future<FreeRelayCredentials> _register(String relay) =>
      _post(_endpoint(relay, '/v1/free/installations'), expectedStatus: 201);

  Future<FreeRelayCredentials> _refresh(String relay, String refreshToken) =>
      _post(
        _endpoint(relay, '/v1/free/token'),
        expectedStatus: 200,
        bearer: refreshToken,
      );

  Future<FreeRelayCredentials> _post(
    Uri endpoint, {
    required int expectedStatus,
    String? bearer,
  }) async {
    final response = await _client
        .post(
          endpoint,
          headers: {
            'accept': 'application/json',
            if (bearer != null) 'authorization': 'Bearer $bearer',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const FreeRelayUnauthorizedException();
    }
    if (response.statusCode != expectedStatus) {
      throw StateError(
        'Free Relay credential request failed (${response.statusCode}).',
      );
    }
    final value = jsonDecode(response.body);
    if (value is! Map) {
      throw const FormatException('Invalid Free Relay credential response.');
    }
    final credentials = FreeRelayCredentials.fromJson(
      value.cast<String, Object?>(),
    );
    if (!credentials.isComplete) {
      throw const FormatException('Incomplete Free Relay credentials.');
    }
    await _secrets.write(
      kEmbeddedFreeRelayCredentialsSecretKey,
      jsonEncode(credentials.toJson()),
    );
    return credentials;
  }

  Uri _endpoint(String relay, String path) {
    final value = relay.trim();
    final base = Uri.parse(value.contains('://') ? value : 'https://$value');
    if (base.host.isEmpty ||
        (base.scheme != 'https' && base.scheme != 'http')) {
      throw FormatException('Invalid Free Relay address: $relay');
    }
    return base.replace(path: path, query: null, fragment: null);
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class FreeRelayUnauthorizedException implements Exception {
  const FreeRelayUnauthorizedException();
}
