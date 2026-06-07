// One-off probe: reproduce the Doubao ASR WS handshake (StartTask +
// StartSession) without mic/opus, to diagnose "expected seq=1 or start
// session". Run with: dart run tool/doubao_handshake_probe.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'dart:ffi' as ffi;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:opus_dart/opus_dart.dart' as opus;
import 'package:motif/motif/platform/doubao_asr/asr_protocol.dart';
import 'package:motif/motif/platform/doubao_asr/doubao_constants.dart';

Future<void> main(List<String> argv) async {
  final badToken = argv.contains('--bad-token');
  final cdid = _uuidV4();
  final openudid = _randomHex(8);
  final clientudid = _uuidV4();

  stdout.writeln('== registering device ==');
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
  final regBody = jsonEncode({
    'magic_tag': 'ss_app_log',
    'header': header,
    '_gen_time': DateTime.now().millisecondsSinceEpoch,
  });
  final regUri = Uri.parse(DoubaoConstants.registerUrl).replace(
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
  final regResp = await http.post(
    regUri,
    headers: {
      HttpHeaders.contentTypeHeader: 'application/json',
      HttpHeaders.userAgentHeader: DoubaoConstants.userAgent,
    },
    body: regBody,
  );
  stdout.writeln('register HTTP ${regResp.statusCode}: ${regResp.body}');
  final regJson = jsonDecode(regResp.body) as Map<String, Object?>;
  final deviceId =
      '${regJson['device_id_str'] ?? regJson['device_id'] ?? ''}';
  stdout.writeln('device_id=$deviceId');

  stdout.writeln('== fetching token ==');
  final tokenBody = utf8.encode('body=null');
  final stub = md5.convert(tokenBody).toString().toUpperCase();
  final tokenUri = Uri.parse(DoubaoConstants.settingsUrl).replace(
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
  final tokenResp = await http.post(
    tokenUri,
    headers: {
      HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
      HttpHeaders.userAgentHeader: DoubaoConstants.userAgent,
      'x-ss-stub': stub,
    },
    body: tokenBody,
  );
  stdout.writeln('settings HTTP ${tokenResp.statusCode}');
  final root = jsonDecode(tokenResp.body) as Map<String, Object?>;
  final data = root['data'] as Map<String, Object?>?;
  final settings = data?['settings'] as Map<String, Object?>?;
  final asrConfig = settings?['asr_config'] as Map<String, Object?>?;
  var token = asrConfig?['app_key'] as String? ?? '';
  if (badToken) {
    stdout.writeln('(--bad-token: using stale/garbage token)');
    token = 'XXXXXXXXXX';
  }
  stdout.writeln(
    'token: ${token.isEmpty ? "<EMPTY>" : "${token.substring(0, min(24, token.length))}... (len=${token.length})"}',
  );

  stdout.writeln('== opening websocket ==');
  final uri = Uri.parse(DoubaoConstants.websocketUrl).replace(
    queryParameters: {
      'aid': DoubaoConstants.aid.toString(),
      'device_id': deviceId,
    },
  );
  final ws = await WebSocket.connect(
    uri.toString(),
    headers: {
      HttpHeaders.userAgentHeader: DoubaoConstants.userAgent,
      'proto-version': 'v2',
      'x-custom-keepalive': 'true',
    },
  ).timeout(const Duration(seconds: 15));
  stdout.writeln('ws connected');

  ws.listen(
    (message) {
      final bytes = Uint8List.fromList(
        message is List<int> ? message : utf8.encode(message as String),
      );
      try {
        final r = AsrResponse.decode(bytes);
        stdout.writeln(
          '<< type=${r.messageType} code=${r.statusCode} '
          'msg="${r.statusMessage}" result=${r.resultJson}',
        );
      } catch (e) {
        stdout.writeln('<< undecodable ($e): $bytes');
      }
    },
    onError: (Object e) => stdout.writeln('ws error: $e'),
    onDone: () => stdout.writeln(
      'ws done code=${ws.closeCode} reason=${ws.closeReason}',
    ),
  );

  final requestId = _uuidV4();
  stdout.writeln('>> StartTask');
  ws.add(AsrMessageBuilder.startTask(requestId: requestId, token: token));
  await Future<void>.delayed(const Duration(seconds: 3));

  if (argv.contains('--audio-before-session')) {
    stdout.writeln('>> TaskRequest (audio before StartSession)');
    ws.add(
      AsrMessageBuilder.taskRequest(
        audio: Uint8List.fromList(List<int>.filled(40, 0x42)),
        requestId: requestId,
        frameState: FrameState.first,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  stdout.writeln('>> StartSession');
  final variant = argv
      .firstWhere((a) => a.startsWith('--variant='), orElse: () => '--variant=')
      .substring('--variant='.length);
  final extra = <String, Object?>{
    'app_name': 'com.android.chrome',
    'cell_compress_rate': 8,
    'did': deviceId,
    'enable_asr_threepass': true,
    'enable_asr_twopass': true,
    'input_mode': 'tool',
  };
  switch (variant) {
    case 'no-multipass':
      extra.remove('enable_asr_threepass');
      extra.remove('enable_asr_twopass');
    case 'no-threepass':
      extra.remove('enable_asr_threepass');
    case 'no-twopass':
      extra.remove('enable_asr_twopass');
    case 'minimal':
      extra
        ..clear()
        ..['did'] = deviceId;
  }
  stdout.writeln('(variant=${variant.isEmpty ? 'default' : variant})');
  final config = jsonEncode({
    'audio_info': {
      'channel': DoubaoConstants.channels,
      'format': 'speech_opus',
      'sample_rate': DoubaoConstants.sampleRate,
    },
    'enable_punctuation': true,
    'enable_speech_rejection': false,
    'extra': extra,
  });
  ws.add(
    AsrMessageBuilder.startSession(
      requestId: requestId,
      token: token,
      configJson: config,
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  final pcmArg = argv.firstWhere(
    (a) => a.startsWith('--pcm-file='),
    orElse: () => '',
  );
  if (argv.contains('--stream-audio') || pcmArg.isNotEmpty) {
    // Stream audio as real opus frames at the app's 20ms cadence, then finish
    // the session. Source: --pcm-file=<raw s16le 16k mono> or a synthesized
    // sine "voice" (bursts + silence).
    // Same `as dynamic` dance as DoubaoSpeechService: opus_dart's conditional
    // import confuses the analyzer about which DynamicLibrary type it takes.
    (opus.initOpus as dynamic)(
      ffi.DynamicLibrary.open('/opt/homebrew/lib/libopus.dylib'),
    );
    final encoder = opus.SimpleOpusEncoder(
      sampleRate: DoubaoConstants.sampleRate,
      channels: DoubaoConstants.channels,
      application: opus.Application.voip,
    );
    Uint8List? pcm;
    if (pcmArg.isNotEmpty) {
      pcm = await File(pcmArg.substring('--pcm-file='.length)).readAsBytes();
    }
    final totalFrames = pcm != null
        ? pcm.length ~/ DoubaoConstants.bytesPerFrame
        : 400; // 8s of 20ms frames
    for (var i = 0; i < totalFrames; i++) {
      final samples = Int16List(DoubaoConstants.samplesPerFrame);
      if (pcm != null) {
        final view = ByteData.sublistView(
          pcm,
          i * DoubaoConstants.bytesPerFrame,
          (i + 1) * DoubaoConstants.bytesPerFrame,
        );
        for (var s = 0; s < samples.length; s++) {
          samples[s] = view.getInt16(s * 2, Endian.little);
        }
      } else {
        final inBurst = (i ~/ 50).isEven; // 1s on, 1s off
        if (inBurst) {
          for (var s = 0; s < samples.length; s++) {
            final t = (i * samples.length + s) / DoubaoConstants.sampleRate;
            samples[s] = (sin(2 * pi * 220 * t) * 12000).toInt();
          }
        }
      }
      final frame = encoder.encode(input: samples);
      ws.add(
        AsrMessageBuilder.taskRequest(
          audio: Uint8List.fromList(frame),
          requestId: requestId,
          frameState: i == 0 ? FrameState.first : FrameState.middle,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    stdout.writeln('>> last frame + FinishSession');
    ws.add(
      AsrMessageBuilder.taskRequest(
        audio: Uint8List.fromList(
          encoder.encode(input: Int16List(DoubaoConstants.samplesPerFrame)),
        ),
        requestId: requestId,
        frameState: FrameState.last,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    ws.add(AsrMessageBuilder.finishSession(requestId: requestId, token: token));
    encoder.destroy();
  }

  await Future<void>.delayed(const Duration(seconds: 3));
  await ws.close();
  exit(0);
}

String _randomHex(int bytes) {
  final random = Random.secure();
  return List<int>.generate(
    bytes,
    (_) => random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
