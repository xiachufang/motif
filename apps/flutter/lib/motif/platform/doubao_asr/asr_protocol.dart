import 'dart:convert';
import 'dart:typed_data';

enum FrameState {
  unspecified(0),
  first(1),
  middle(3),
  last(9);

  final int value;
  const FrameState(this.value);
}

class AsrRequest {
  String token = '';
  String serviceName = 'ASR';
  String methodName = '';
  String payload = '';
  Uint8List audioData = Uint8List(0);
  String requestId = '';
  FrameState frameState = FrameState.unspecified;

  Uint8List encode() {
    final buf = BytesBuilder(copy: false);
    _Wire.writeString(2, token, buf);
    _Wire.writeString(3, serviceName, buf);
    _Wire.writeString(5, methodName, buf);
    _Wire.writeString(6, payload, buf);
    _Wire.writeBytes(7, audioData, buf);
    _Wire.writeString(8, requestId, buf);
    _Wire.writeInt32(9, frameState.value, buf);
    return buf.takeBytes();
  }
}

class AsrResponse {
  final String requestId;
  final String taskId;
  final String serviceName;
  final String messageType;
  final int statusCode;
  final String statusMessage;
  final String resultJson;

  const AsrResponse({
    this.requestId = '',
    this.taskId = '',
    this.serviceName = '',
    this.messageType = '',
    this.statusCode = 0,
    this.statusMessage = '',
    this.resultJson = '',
  });

  factory AsrResponse.decode(Uint8List data) {
    final fields = _Wire.decodeFields(data);
    return AsrResponse(
      requestId: _string(fields[1]),
      taskId: _string(fields[2]),
      serviceName: _string(fields[3]),
      messageType: _string(fields[4]),
      statusCode: _int(fields[5]),
      statusMessage: _string(fields[6]),
      resultJson: _string(fields[7]),
    );
  }

  static String _string(_WireField? field) => field is _LengthField
      ? utf8.decode(field.bytes, allowMalformed: true)
      : '';

  static int _int(_WireField? field) => field is _VarintField ? field.value : 0;
}

class AsrMessageBuilder {
  static Uint8List startTask({
    required String requestId,
    required String token,
  }) {
    return (AsrRequest()
          ..token = token
          ..serviceName = 'ASR'
          ..methodName = 'StartTask'
          ..requestId = requestId)
        .encode();
  }

  static Uint8List startSession({
    required String requestId,
    required String token,
    required String configJson,
  }) {
    return (AsrRequest()
          ..token = token
          ..serviceName = 'ASR'
          ..methodName = 'StartSession'
          ..requestId = requestId
          ..payload = configJson)
        .encode();
  }

  static Uint8List finishSession({
    required String requestId,
    required String token,
  }) {
    return (AsrRequest()
          ..token = token
          ..serviceName = 'ASR'
          ..methodName = 'FinishSession'
          ..requestId = requestId)
        .encode();
  }

  static Uint8List taskRequest({
    required Uint8List audio,
    required String requestId,
    required FrameState frameState,
    required int timestampMs,
  }) {
    return (AsrRequest()
          ..serviceName = 'ASR'
          ..methodName = 'TaskRequest'
          ..payload = '{"extra":{},"timestamp_ms":$timestampMs}'
          ..audioData = audio
          ..requestId = requestId
          ..frameState = frameState)
        .encode();
  }
}

sealed class _WireField {
  const _WireField();
}

class _VarintField extends _WireField {
  final int value;
  const _VarintField(this.value);
}

class _LengthField extends _WireField {
  final Uint8List bytes;
  const _LengthField(this.bytes);
}

class _Wire {
  static void writeVarint(int value, BytesBuilder buf) {
    var v = value;
    while (v >= 0x80) {
      buf.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    buf.addByte(v);
  }

  static void writeTag(int field, int type, BytesBuilder buf) {
    writeVarint((field << 3) | type, buf);
  }

  static void writeString(int field, String value, BytesBuilder buf) {
    if (value.isEmpty) return;
    writeTag(field, 2, buf);
    final bytes = utf8.encode(value);
    writeVarint(bytes.length, buf);
    buf.add(bytes);
  }

  static void writeBytes(int field, Uint8List value, BytesBuilder buf) {
    if (value.isEmpty) return;
    writeTag(field, 2, buf);
    writeVarint(value.length, buf);
    buf.add(value);
  }

  static void writeInt32(int field, int value, BytesBuilder buf) {
    if (value == 0) return;
    writeTag(field, 0, buf);
    writeVarint(value & 0xffffffff, buf);
  }

  static int readVarint(Uint8List data, _Index index) {
    var result = 0;
    var shift = 0;
    while (index.value < data.length) {
      final byte = data[index.value++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 64) throw const FormatException('invalid varint');
    }
    throw const FormatException('truncated varint');
  }

  static Map<int, _WireField> decodeFields(Uint8List data) {
    final out = <int, _WireField>{};
    final index = _Index();
    while (index.value < data.length) {
      final tag = readVarint(data, index);
      final field = tag >> 3;
      final wireType = tag & 0x7;
      switch (wireType) {
        case 0:
          out[field] = _VarintField(readVarint(data, index));
        case 2:
          final length = readVarint(data, index);
          final end = index.value + length;
          if (end > data.length) throw const FormatException('truncated field');
          out[field] = _LengthField(
            Uint8List.sublistView(data, index.value, end),
          );
          index.value = end;
        default:
          throw FormatException('unsupported wire type $wireType');
      }
    }
    return out;
  }
}

class _Index {
  int value = 0;
}
