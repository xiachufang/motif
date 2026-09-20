// Fixtures adapted from rhinoc/douvo d68cf190, covered by
// lib/motif/platform/doubao_asr/DOUVO_LICENSE.txt.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/doubao_asr/doubao_transcript.dart';

void main() {
  final fixtures =
      jsonDecode(
            File('test/motif/fixtures/doubao_results.json').readAsStringSync(),
          )
          as List;
  for (final fixture in fixtures.cast<Map>()) {
    test('Douvo regression: ${fixture['name']}', () {
      final assembler = DoubaoTranscriptAssembler();
      var text = '';
      for (final frame in fixture['frames'] as List) {
        final result = DoubaoRecognitionResult.parse(
          (frame as Map).cast<String, Object?>(),
        )!;
        text = fixture['assemble'] == true
            ? assembler.update(result)
            : result.text;
      }
      expect(text, fixture['expected']);
    });
  }

  test('legacy multi-piece results also survive the service assembler', () {
    final fixture = fixtures.first as Map;
    final result = DoubaoRecognitionResult.parse(
      ((fixture['frames'] as List).first as Map).cast<String, Object?>(),
    )!;
    final assembler = DoubaoTranscriptAssembler();
    expect(assembler.update(result), fixture['expected']);
    expect(assembler.update(result), fixture['expected']);
  });

  test('sentence final flags do not finalize the cumulative interim', () {
    final result = DoubaoRecognitionResult.parse({
      'results': [
        {'text': '今天天气不错。我们', 'start_time': 0, 'is_interim': true},
        {
          'text': '今天天气不错。',
          'is_interim': false,
          'extra': {'nonstream_result': true},
        },
        {'text': '我们', 'is_interim': true},
      ],
    })!;
    expect(result.isCumulative, isTrue);
    expect(result.isFinal, isFalse);
    expect(result.text, '今天天气不错。我们');
  });

  test('whole-transcript post-process is final without a VAD flag', () {
    final result = DoubaoRecognitionResult.parse({
      'results': [
        {'text': '最终修订。', 'is_interim': false},
      ],
    })!;
    expect(result.isFinal, isTrue);
  });

  test('nonstream is final even when is_interim is absent', () {
    final result = DoubaoRecognitionResult.parse({
      'results': [
        {
          'text': '最终结果',
          'extra': {'nonstream_result': true},
        },
      ],
    })!;
    expect(result.isFinal, isTrue);
  });

  test('snapshot revisions replace even when shorter, reset clears mode', () {
    final assembler = DoubaoTranscriptAssembler();
    assembler.update(
      DoubaoRecognitionResult.parse({
        'results': [
          {'text': '第一句。第二句。', 'is_interim': true},
          {'text': '第一句。', 'is_interim': false},
          {'text': '第二句。', 'is_interim': true},
        ],
      })!,
    );
    expect(
      assembler.update(
        DoubaoRecognitionResult.parse({
          'results': [
            {'text': '合并修订。', 'is_interim': false},
          ],
        })!,
      ),
      '合并修订。',
    );
    assembler.reset();
    expect(assembler.text, isEmpty);
    for (var i = 0; i < 2; i++) {
      assembler.update(
        DoubaoRecognitionResult.parse({
          'results': [
            {
              'text': '句$i。',
              'start_time': i * 100,
              'end_time': (i + 1) * 100,
              'is_interim': false,
            },
          ],
        })!,
      );
    }
    expect(assembler.text, '句0。句1。');
  });

  test('missing or empty results leave accumulated text intact', () {
    expect(DoubaoRecognitionResult.parse({}), isNull);
    expect(DoubaoRecognitionResult.parse({'results': []}), isNull);
    final assembler = DoubaoTranscriptAssembler();
    assembler.update(
      DoubaoRecognitionResult.parse({
        'results': [
          {'text': '保留', 'is_interim': true},
        ],
      })!,
    );
    assembler.update(
      DoubaoRecognitionResult.parse({
        'results': [
          {'text': '', 'is_interim': false},
        ],
      })!,
    );
    expect(assembler.text, '保留');
  });
}
