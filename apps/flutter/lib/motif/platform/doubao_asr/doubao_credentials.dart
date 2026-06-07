import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'doubao_constants.dart';

class DeviceCredentials {
  final String deviceId;
  final String installId;
  final String cdid;
  final String openudid;
  final String clientudid;
  final String token;

  const DeviceCredentials({
    required this.deviceId,
    required this.installId,
    required this.cdid,
    required this.openudid,
    required this.clientudid,
    required this.token,
  });

  DeviceCredentials copyWith({String? token}) => DeviceCredentials(
    deviceId: deviceId,
    installId: installId,
    cdid: cdid,
    openudid: openudid,
    clientudid: clientudid,
    token: token ?? this.token,
  );

  factory DeviceCredentials.fromJson(Map<String, Object?> json) =>
      DeviceCredentials(
        deviceId: json['deviceId'] as String? ?? '',
        installId: json['installId'] as String? ?? '',
        cdid: json['cdid'] as String? ?? '',
        openudid: json['openudid'] as String? ?? '',
        clientudid: json['clientudid'] as String? ?? '',
        token: json['token'] as String? ?? '',
      );

  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'installId': installId,
    'cdid': cdid,
    'openudid': openudid,
    'clientudid': clientudid,
    'token': token,
  };
}

class DoubaoException implements Exception {
  final String message;
  const DoubaoException(this.message);

  @override
  String toString() => message;
}

class DoubaoCredentialStore {
  DoubaoCredentialStore._();
  static final shared = DoubaoCredentialStore._();

  DeviceCredentials? _cached;
  Future<File>? _fileFuture;

  void warmup() {
    // The first anonymous device registration is the only slow part of ASR
    // startup. Run it opportunistically after app boot, mirroring iOS Motif.
    ensureCredentials().ignore();
  }

  Future<void> reset() async {
    _cached = null;
    final file = await _credentialsFile();
    if (await file.exists()) await file.delete();
  }

  Future<DeviceCredentials> ensureCredentials() async {
    final loaded = _cached ?? await _load();
    if (loaded != null && loaded.deviceId.isNotEmpty) {
      if (loaded.token.isEmpty || _isJwtExpired(loaded.token)) {
        final token = await _fetchToken(
          deviceId: loaded.deviceId,
          cdid: loaded.cdid,
        );
        final refreshed = loaded.copyWith(token: token);
        _cached = refreshed;
        await _save(refreshed);
        return refreshed;
      }
      _cached = loaded;
      return loaded;
    }

    final registered = await _registerDevice();
    final token = await _fetchToken(
      deviceId: registered.deviceId,
      cdid: registered.cdid,
    );
    final fresh = registered.copyWith(token: token);
    _cached = fresh;
    await _save(fresh);
    return fresh;
  }

  Future<DeviceCredentials?> _load() async {
    final file = await _credentialsFile();
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      return DeviceCredentials.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(DeviceCredentials credentials) async {
    final file = await _credentialsFile();
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(credentials.toJson()));
  }

  Future<File> _credentialsFile() {
    return _fileFuture ??= () async {
      final support = await getApplicationSupportDirectory();
      return File('${support.path}/SpeechMore/credentials.json');
    }();
  }

  Future<DeviceCredentials> _registerDevice() async {
    final cdid = _uuidV4();
    final openudid = _randomHex(8);
    final clientudid = _uuidV4();

    final header = <String, Object>{
      ...DoubaoConstants.appConfig,
      ...DoubaoConstants.deviceConfig,
      'device_id': 0,
      'install_id': 0,
      'openudid': openudid,
      'clientudid': clientudid,
      'cdid': cdid,
      'region': 'CN',
      'tz_name': 'Asia/Shanghai',
      'tz_offset': 28800,
      'sim_region': 'cn',
      'carrier_region': 'cn',
      'cpu_abi': 'arm64-v8a',
      'build_serial': 'unknown',
      'not_request_sender': 0,
      'sig_hash': '',
      'google_aid': '',
      'mc': '',
      'serial_number': '',
    };
    final body = jsonEncode({
      'magic_tag': 'ss_app_log',
      'header': header,
      '_gen_time': DateTime.now().millisecondsSinceEpoch,
    });

    final uri = Uri.parse(DoubaoConstants.registerUrl).replace(
      queryParameters: {
        'device_platform': 'android',
        'os': 'android',
        'ssmix': 'a',
        '_rticket': DateTime.now().millisecondsSinceEpoch.toString(),
        'cdid': cdid,
        'channel': '${DoubaoConstants.appConfig['channel']}',
        'aid': '${DoubaoConstants.aid}',
        'app_name': '${DoubaoConstants.appConfig['app_name']}',
        'version_code': '${DoubaoConstants.appConfig['version_code']}',
        'version_name': '${DoubaoConstants.appConfig['version_name']}',
        'manifest_version_code':
            '${DoubaoConstants.appConfig['manifest_version_code']}',
        'update_version_code':
            '${DoubaoConstants.appConfig['update_version_code']}',
        'resolution': '${DoubaoConstants.deviceConfig['resolution']}',
        'dpi': '${DoubaoConstants.deviceConfig['dpi']}',
        'device_type': '${DoubaoConstants.deviceConfig['device_type']}',
        'device_brand': '${DoubaoConstants.deviceConfig['device_brand']}',
        'language': '${DoubaoConstants.deviceConfig['language']}',
        'os_api': '${DoubaoConstants.deviceConfig['os_api']}',
        'os_version': '${DoubaoConstants.deviceConfig['os_version']}',
        'ac': 'wifi',
      },
    );

    final response = await http
        .post(
          uri,
          headers: {
            HttpHeaders.contentTypeHeader: 'application/json',
            HttpHeaders.userAgentHeader: DoubaoConstants.userAgent,
          },
          body: body,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DoubaoException(
        'Device registration failed: HTTP ${response.statusCode}: ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, Object?>;
    final deviceId = _firstNonEmptyId(json['device_id_str'], json['device_id']);
    if (deviceId.isEmpty || deviceId == '0') {
      throw DoubaoException('Device registration failed: missing device_id');
    }
    return DeviceCredentials(
      deviceId: deviceId,
      installId: _firstNonEmptyId(json['install_id_str'], json['install_id']),
      cdid: cdid,
      openudid: openudid,
      clientudid: clientudid,
      token: '',
    );
  }

  Future<String> _fetchToken({
    required String deviceId,
    required String cdid,
  }) async {
    final body = utf8.encode('body=null');
    final stub = md5.convert(body).toString().toUpperCase();
    final uri = Uri.parse(DoubaoConstants.settingsUrl).replace(
      queryParameters: {
        'device_platform': 'android',
        'os': 'android',
        'ssmix': 'a',
        '_rticket': DateTime.now().millisecondsSinceEpoch.toString(),
        'cdid': cdid,
        'channel': '${DoubaoConstants.appConfig['channel']}',
        'aid': '${DoubaoConstants.aid}',
        'app_name': '${DoubaoConstants.appConfig['app_name']}',
        'version_code': '${DoubaoConstants.appConfig['version_code']}',
        'version_name': '${DoubaoConstants.appConfig['version_name']}',
        'device_id': deviceId,
      },
    );

    final response = await http
        .post(
          uri,
          headers: {
            HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
            HttpHeaders.userAgentHeader: DoubaoConstants.userAgent,
            'x-ss-stub': stub,
          },
          body: body,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DoubaoException(
        'Token fetch failed: HTTP ${response.statusCode}: ${response.body}',
      );
    }
    final root = jsonDecode(response.body) as Map<String, Object?>;
    final data = root['data'] as Map<String, Object?>?;
    final settings = data?['settings'] as Map<String, Object?>?;
    final asrConfig = settings?['asr_config'] as Map<String, Object?>?;
    final appKey = asrConfig?['app_key'] as String?;
    if (appKey == null || appKey.isEmpty) {
      throw const DoubaoException(
        'Token fetch failed: missing data.settings.asr_config.app_key',
      );
    }
    return appKey;
  }

  static bool _isJwtExpired(
    String token, {
    Duration margin = const Duration(seconds: 60),
  }) {
    final parts = token.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final json = jsonDecode(payload) as Map<String, Object?>;
      final exp = (json['exp'] as num?)?.toDouble();
      if (exp == null) return false;
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      return now >= exp - margin.inSeconds;
    } catch (_) {
      return false;
    }
  }

  static String _stringId(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num) return value.toInt().toString();
    return value.toString();
  }

  static String _firstNonEmptyId(Object? preferred, Object? fallback) {
    final first = _stringId(preferred);
    return first.isNotEmpty ? first : _stringId(fallback);
  }

  static String _randomHex(int bytes) {
    final random = Random.secure();
    return List<int>.generate(
      bytes,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
