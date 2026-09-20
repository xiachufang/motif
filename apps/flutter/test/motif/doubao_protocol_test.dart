import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/doubao_asr/asr_protocol.dart';
import 'package:motif/motif/platform/doubao_asr/doubao_session_config.dart';

void main() {
  test(
    'Android session enables final post-processing without a personal lexicon',
    () {
      final config = doubaoSessionConfig('test-device');
      expect(config['audio_info'], {
        'channel': 1,
        'format': 'speech_opus',
        'sample_rate': 16000,
      });
      final extra = config['extra'] as Map;
      expect(extra['enable_asr_twopass'], isTrue);
      expect(extra['enable_asr_threepass'], isTrue);
      expect(extra['enable_text_post_process'], isTrue);
      expect(extra['asr_text_post_process_type'], 'last_post_process');
      expect(extra['disable_user_words'], isTrue);
      expect(extra['did'], 'test-device');
      expect(extra.containsKey('context'), isFalse);
    },
  );

  test('only the LAST audio packet forces final two-pass recognition', () {
    for (final state in [
      FrameState.first,
      FrameState.middle,
      FrameState.last,
    ]) {
      final fields = _decode(
        AsrMessageBuilder.taskRequest(
          audio: Uint8List.fromList([0x48, 0x00]),
          requestId: 'request',
          frameState: state,
          timestampMs: 1020,
        ),
      );
      final payload = jsonDecode(utf8.decode(fields[6] as List<int>)) as Map;
      expect(payload['timestamp_ms'], 1020);
      expect(
        payload['extra'],
        state == FrameState.last
            ? {'finish_audio': true, 'force_asr_twopass': true}
            : {},
      );
      expect(fields[7], [0x48, 0x00]);
      expect(fields[9], state.value);
      expect(fields.containsKey(2), isFalse);
    }
  });

  test('finish follows the same task identity and credential', () {
    final fields = _decode(
      AsrMessageBuilder.finishSession(
        requestId: 'request',
        token: 'test-token',
      ),
    );
    expect(utf8.decode(fields[2] as List<int>), 'test-token');
    expect(utf8.decode(fields[5] as List<int>), 'FinishSession');
    expect(utf8.decode(fields[8] as List<int>), 'request');
  });
}

// Independent minimal decoder checks the actual wire payload, not the builder's
// intermediate JSON. These requests only contain varints and byte strings.
Map<int, Object> _decode(Uint8List bytes) {
  var offset = 0;
  int varint() {
    var value = 0;
    var shift = 0;
    while (true) {
      final byte = bytes[offset++];
      value |= (byte & 127) << shift;
      if (byte < 128) return value;
      shift += 7;
    }
  }

  final fields = <int, Object>{};
  while (offset < bytes.length) {
    final tag = varint();
    if (tag & 7 == 0) {
      fields[tag >> 3] = varint();
    } else {
      expect(tag & 7, 2);
      final length = varint();
      fields[tag >> 3] = bytes.sublist(offset, offset + length);
      offset += length;
    }
  }
  return fields;
}
