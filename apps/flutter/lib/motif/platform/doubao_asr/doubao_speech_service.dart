import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart' as opus;
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:record/record.dart';

import '../services.dart';
import 'asr_protocol.dart';
import 'doubao_constants.dart';
import 'doubao_credentials.dart';

class DoubaoSpeechService implements SpeechService {
  _DoubaoASR? _asr;
  String _lastText = '';

  DoubaoSpeechService() {
    DoubaoCredentialStore.shared.warmup();
  }

  @override
  bool get isAvailable => true;

  @override
  Future<void> start({
    required void Function(String partial) onPartial,
    void Function(double level)? onLevel,
    void Function(Object error)? onError,
  }) async {
    if (_asr != null) {
      await stop();
    }
    _lastText = '';
    final asr = _DoubaoASR(
      onPartial: (text) {
        _lastText = text;
        onPartial(text);
      },
      onAudioLevel: (level) => onLevel?.call(level),
      onError: (error) => onError?.call(error),
    );
    _asr = asr;
    try {
      await asr.start();
    } catch (error) {
      _asr = null;
      rethrow;
    }
  }

  @override
  Future<String> stop() async {
    final asr = _asr;
    if (asr == null) return _lastText;
    _asr = null;
    _lastText = await asr.stop();
    return _lastText;
  }
}

class _DoubaoASR {
  final void Function(String text) onPartial;
  final void Function(double level)? onAudioLevel;
  final void Function(Object error)? onError;

  _DoubaoASR({
    required this.onPartial,
    required this.onAudioLevel,
    required this.onError,
  });

  static Future<void>? _opusInit;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioSub;
  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;

  opus.SimpleOpusEncoder? _encoder;
  DeviceCredentials? _credentials;

  String _requestId = '';
  final List<int> _pcmBuffer = <int>[];
  bool _didSendFirstFrame = false;
  bool _canSendAudio = false;
  bool _isRunning = false;
  bool _isFinalizing = false;

  final List<String> _committedSegments = <String>[];
  String _currentInterim = '';

  Future<void> _flushFuture = Future<void>.value();
  Completer<void>? _finishedCompleter;
  bool Function(AsrResponse response)? _pendingResponseFilter;
  Completer<AsrResponse>? _pendingResponseCompleter;

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _isFinalizing = false;
    _requestId = _uuidV4();
    _committedSegments.clear();
    _currentInterim = '';
    _pcmBuffer.clear();
    _didSendFirstFrame = false;
    _canSendAudio = false;
    _finishedCompleter = Completer<void>();

    try {
      final granted = await _recorder.hasPermission();
      if (!granted) {
        throw const DoubaoException('Microphone permission denied');
      }
      await _ensureOpus();
      _encoder = opus.SimpleOpusEncoder(
        sampleRate: DoubaoConstants.sampleRate,
        channels: DoubaoConstants.channels,
        application: opus.Application.voip,
      );
      _credentials = await DoubaoCredentialStore.shared.ensureCredentials();
      await _startMicStream();
      await _openWebSocket();
      await _sendInitialMessages();
      _canSendAudio = true;
      _scheduleFlush();
      await _flushFuture;
    } catch (error) {
      await _cleanupAfterStartFailure();
      rethrow;
    }
  }

  Future<String> stop() async {
    if (!_isRunning && !_isFinalizing) return _assembledText();
    _isFinalizing = true;

    try {
      await _stopMicStream();
      await _flushFuture.catchError((_) {});
      try {
        await _flushAndSendLastFrame();
        await _sendFinishSession();
      } catch (error) {
        _deliverError(error);
      }

      final finished = _finishedCompleter?.future;
      if (finished != null) {
        await finished.timeout(
          const Duration(milliseconds: 2500),
          onTimeout: () {},
        );
      }
      return _assembledText();
    } finally {
      _isRunning = false;
      _isFinalizing = false;
      await _closeWebSocket();
      _encoder?.destroy();
      _encoder = null;
      await _recorder.dispose();
    }
  }

  static Future<void> _ensureOpus() async {
    final existing = _opusInit;
    if (existing != null) {
      try {
        await existing;
        return;
      } catch (_) {
        _opusInit = null;
      }
    }
    final init = _initializeOpus();
    _opusInit = init;
    await init;
  }

  static Future<void> _initializeOpus() async {
    try {
      if (Platform.isIOS) {
        (opus.initOpus as dynamic)(ffi.DynamicLibrary.process());
        return;
      }
      opus.initOpus(await opus_flutter.load());
    } catch (_) {
      _opusInit = null;
      rethrow;
    }
  }

  Future<void> _startMicStream() async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: DoubaoConstants.sampleRate,
        numChannels: DoubaoConstants.channels,
        streamBufferSize: DoubaoConstants.bytesPerFrame,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        iosConfig: IosRecordConfig(
          categoryOptions: [
            IosAudioCategoryOption.allowBluetooth,
            IosAudioCategoryOption.defaultToSpeaker,
            IosAudioCategoryOption.mixWithOthers,
          ],
        ),
      ),
    );
    _audioSub = stream.listen(
      _appendAndDrainPcm,
      onError: _deliverError,
      cancelOnError: false,
    );
  }

  Future<void> _stopMicStream() async {
    try {
      await _recorder.stop();
    } catch (_) {}
    await _audioSub?.cancel();
    _audioSub = null;
  }

  Future<void> _cleanupAfterStartFailure() async {
    _isRunning = false;
    _isFinalizing = false;
    await _stopMicStream();
    await _closeWebSocket();
    _encoder?.destroy();
    _encoder = null;
    await _recorder.dispose();
  }

  Future<void> _openWebSocket() async {
    final credentials = _credentials;
    if (credentials == null) {
      throw const DoubaoException('Missing Doubao credentials');
    }
    final uri = Uri.parse(DoubaoConstants.websocketUrl).replace(
      queryParameters: {
        'aid': DoubaoConstants.aid.toString(),
        'device_id': credentials.deviceId,
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
    _ws = ws;
    _wsSub = ws.listen(
      _handleWebSocketMessage,
      onError: _handleWebSocketError,
      onDone: _handleWebSocketDone,
      cancelOnError: false,
    );
  }

  Future<void> _sendInitialMessages() async {
    final credentials = _credentials;
    if (credentials == null) {
      throw const DoubaoException('Missing Doubao credentials');
    }
    await _sendData(
      AsrMessageBuilder.startTask(
        requestId: _requestId,
        token: credentials.token,
      ),
    );
    final task = await _waitForResponse(
      const Duration(seconds: 5),
      (r) =>
          r.messageType == 'TaskStarted' ||
          r.messageType == 'TaskFailed' ||
          r.messageType == 'SessionFailed',
    );
    if (task.messageType != 'TaskStarted') {
      throw DoubaoException(
        'StartTask: ${task.statusMessage.isEmpty ? 'failed' : task.statusMessage} (${task.statusCode})',
      );
    }

    await _sendData(
      AsrMessageBuilder.startSession(
        requestId: _requestId,
        token: credentials.token,
        configJson: _sessionConfigJson(credentials.deviceId),
      ),
    );
    final session = await _waitForResponse(
      const Duration(seconds: 5),
      (r) =>
          r.messageType == 'SessionStarted' ||
          r.messageType == 'TaskFailed' ||
          r.messageType == 'SessionFailed',
    );
    if (session.messageType != 'SessionStarted') {
      throw DoubaoException(
        'StartSession: ${session.statusMessage.isEmpty ? 'failed' : session.statusMessage} (${session.statusCode})',
      );
    }
  }

  String _sessionConfigJson(String deviceId) {
    return jsonEncode({
      'audio_info': {
        'channel': DoubaoConstants.channels,
        'format': 'speech_opus',
        'sample_rate': DoubaoConstants.sampleRate,
      },
      'enable_punctuation': true,
      'enable_speech_rejection': false,
      'extra': {
        'app_name': 'com.android.chrome',
        'cell_compress_rate': 8,
        'did': deviceId,
        'enable_asr_threepass': true,
        'enable_asr_twopass': true,
        'input_mode': 'tool',
      },
    });
  }

  Future<AsrResponse> _waitForResponse(
    Duration timeout,
    bool Function(AsrResponse response) predicate,
  ) async {
    final completer = Completer<AsrResponse>();
    _pendingResponseFilter = predicate;
    _pendingResponseCompleter = completer;
    try {
      return await completer.future.timeout(timeout);
    } finally {
      if (identical(_pendingResponseCompleter, completer)) {
        _pendingResponseFilter = null;
        _pendingResponseCompleter = null;
      }
    }
  }

  void _handleWebSocketMessage(Object? message) {
    final data = switch (message) {
      Uint8List bytes => bytes,
      List<int> bytes => Uint8List.fromList(bytes),
      String text => Uint8List.fromList(utf8.encode(text)),
      _ => Uint8List(0),
    };
    if (data.isEmpty) return;
    try {
      _handleResponseData(data);
    } catch (error) {
      _deliverError(error);
    }
  }

  void _handleWebSocketError(Object error) {
    _pendingResponseCompleter?.completeError(error);
    _pendingResponseCompleter = null;
    _pendingResponseFilter = null;
    if (_isRunning && !_isFinalizing) _deliverError(error);
    _signalFinished();
  }

  void _handleWebSocketDone() {
    if (_isRunning && !_isFinalizing) {
      _deliverError(const DoubaoException('ASR WebSocket closed'));
    }
    _signalFinished();
  }

  void _handleResponseData(Uint8List data) {
    final response = AsrResponse.decode(data);
    if (response.requestId.isNotEmpty &&
        _requestId.isNotEmpty &&
        response.requestId != _requestId) {
      return;
    }

    final pending = _pendingResponseFilter;
    if (pending != null && pending(response)) {
      _pendingResponseFilter = null;
      _pendingResponseCompleter?.complete(response);
      _pendingResponseCompleter = null;
      return;
    }

    switch (response.messageType) {
      case 'SessionFinished':
        _signalFinished();
        return;
      case 'TaskFailed':
      case 'SessionFailed':
        final message = response.statusMessage.isEmpty
            ? 'ASR failed (${response.statusCode})'
            : '${response.statusMessage} (${response.statusCode})';
        _deliverError(DoubaoException(message));
        _signalFinished();
        return;
    }

    if (response.resultJson.isEmpty) return;
    final root = jsonDecode(response.resultJson) as Map<String, Object?>;
    final results = root['results'];
    if (results is! List || results.isEmpty) return;

    var text = '';
    var isInterim = true;
    var vadFinished = false;
    var nonstreamResult = false;
    for (final item in results) {
      if (item is! Map) continue;
      final result = item.cast<String, Object?>();
      final resultText = result['text'];
      if (resultText is String && resultText.isNotEmpty) text = resultText;
      if (result['is_interim'] == false) isInterim = false;
      if (result['is_vad_finished'] == true) vadFinished = true;
      final extra = result['extra'];
      if (extra is Map && extra['nonstream_result'] == true) {
        nonstreamResult = true;
      }
    }

    if (text.isEmpty) return;
    if ((!isInterim && vadFinished) || nonstreamResult) {
      _committedSegments.add(text);
      _currentInterim = '';
    } else {
      _currentInterim = text;
    }
    onPartial(_assembledText());
  }

  void _appendAndDrainPcm(Uint8List data) {
    if (!_isRunning || _isFinalizing) return;
    _pcmBuffer.addAll(data);
    _emitAudioLevel(data);
    if (_canSendAudio) _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushFuture = _flushFuture
        .catchError((Object error) {
          _deliverError(error);
        })
        .then((_) => _flushPendingFrames())
        .catchError((Object error) {
          _deliverError(error);
        });
  }

  Future<void> _flushPendingFrames() async {
    if (!_canSendAudio) return;
    const frameSize = DoubaoConstants.bytesPerFrame;
    while (!_isFinalizing && _pcmBuffer.length >= frameSize) {
      final frame = Uint8List.fromList(_pcmBuffer.sublist(0, frameSize));
      _pcmBuffer.removeRange(0, frameSize);
      final state = _didSendFirstFrame ? FrameState.middle : FrameState.first;
      await _encodeAndSend(frame, state);
      _didSendFirstFrame = true;
    }
  }

  Future<void> _flushAndSendLastFrame() async {
    const frameSize = DoubaoConstants.bytesPerFrame;
    if (_pcmBuffer.isEmpty) {
      if (_didSendFirstFrame) {
        await _encodeAndSend(Uint8List(frameSize), FrameState.last);
      }
      return;
    }
    if (_pcmBuffer.length < frameSize) {
      _pcmBuffer.addAll(Uint8List(frameSize - _pcmBuffer.length));
    }
    final frame = Uint8List.fromList(_pcmBuffer.sublist(0, frameSize));
    _pcmBuffer.clear();
    await _encodeAndSend(frame, FrameState.last);
  }

  Future<void> _encodeAndSend(Uint8List pcmFrame, FrameState state) async {
    final encoder = _encoder;
    if (encoder == null) return;
    final opusFrame = encoder.encode(input: _pcmFrameToSamples(pcmFrame));
    await _sendData(
      AsrMessageBuilder.taskRequest(
        audio: opusFrame,
        requestId: _requestId,
        frameState: state,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _sendFinishSession() async {
    final token = _credentials?.token;
    if (token == null) return;
    await _sendData(
      AsrMessageBuilder.finishSession(requestId: _requestId, token: token),
    );
  }

  Future<void> _sendData(Uint8List data) async {
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) {
      throw const DoubaoException('ASR WebSocket is not connected');
    }
    ws.add(data);
  }

  Future<void> _closeWebSocket() async {
    final ws = _ws;
    _ws = null;
    _pendingResponseCompleter?.completeError(
      const DoubaoException('ASR WebSocket closed'),
    );
    _pendingResponseCompleter = null;
    _pendingResponseFilter = null;
    if (ws != null && ws.readyState == WebSocket.open) {
      await ws
          .close(WebSocketStatus.normalClosure)
          .timeout(const Duration(seconds: 1), onTimeout: () {});
    }
    await _wsSub?.cancel();
    _wsSub = null;
  }

  void _emitAudioLevel(Uint8List pcm) {
    final callback = onAudioLevel;
    if (callback == null || pcm.length < 2) return;
    final data = ByteData.sublistView(pcm);
    var sum = 0.0;
    final samples = pcm.length ~/ 2;
    for (var i = 0; i < samples; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
      sum += sample * sample;
    }
    callback(min(1.0, sqrt(sum / samples) * 6.0));
  }

  Int16List _pcmFrameToSamples(Uint8List pcmFrame) {
    final data = ByteData.sublistView(pcmFrame);
    final samples = Int16List(pcmFrame.length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little);
    }
    return samples;
  }

  String _assembledText() => _committedSegments.join() + _currentInterim;

  void _signalFinished() {
    final completer = _finishedCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _deliverError(Object error) => onError?.call(error);

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
