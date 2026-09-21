// Fixtures adapted from rhinoc/douvo d68cf190, covered by
// lib/motif/platform/doubao_asr/DOUVO_LICENSE.txt.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/doubao_asr/doubao_transcript.dart';

void main() {
  Map<String, Object?> segment(
    String text, {
    int start = 0,
    int end = 1000,
    bool finalResult = true,
  }) => {
    'text': text,
    'start_time': start,
    'end_time': end,
    'is_interim': !finalResult,
  };

  String update(
    DoubaoTranscriptAssembler assembler,
    List<Map<String, Object?>> segments,
  ) => assembler.update(DoubaoRecognitionResult.parse({'results': segments})!);

  test('replayed final frames are idempotent', () {
    final assembler = DoubaoTranscriptAssembler();
    final frame = [segment('请检查重复插入。')];
    expect(update(assembler, frame), '请检查重复插入。');
    expect(update(assembler, frame), '请检查重复插入。');
  });

  test(
    'late final correction replaces committed text and preserves active',
    () {
      final assembler = DoubaoTranscriptAssembler();
      update(assembler, [segment('请检查检查。')]);
      update(assembler, [
        segment('下一句', start: 1000, end: 2000, finalResult: false),
      ]);
      expect(update(assembler, [segment('请检查。')]), '请检查。下一句');
      expect(
        update(assembler, [segment('请检查检查', finalResult: false)]),
        '请检查。下一句',
      );
    },
  );

  test('replayed sentence batches do not append committed sentences', () {
    final assembler = DoubaoTranscriptAssembler();
    final first = segment('第一句。');
    update(assembler, [first]);
    final batch = [first, segment('第二句。', start: 1000, end: 2000)];
    expect(update(assembler, batch), '第一句。第二句。');
    expect(update(assembler, batch), '第一句。第二句。');
  });

  test('final can revise a window committed by the following interim', () {
    final assembler = DoubaoTranscriptAssembler();
    update(assembler, [segment('第一句句', finalResult: false)]);
    update(assembler, [
      segment('第二句', start: 1000, end: 2000, finalResult: false),
    ]);
    expect(update(assembler, [segment('第一句。')]), '第一句。第二句');
  });

  test('slightly shifted final window replaces the committed window', () {
    final assembler = DoubaoTranscriptAssembler();
    update(assembler, [segment('检查检查。')]);
    expect(update(assembler, [segment('检查。', start: 20)]), '检查。');
  });

  test('identical speech in distinct time windows is preserved', () {
    final assembler = DoubaoTranscriptAssembler();
    update(assembler, [segment('测试。')]);
    expect(
      update(assembler, [segment('测试。', start: 1000, end: 2000)]),
      '测试。测试。',
    );
  });

  test('untimed final revisions replace the same candidate', () {
    final assembler = DoubaoTranscriptAssembler();
    update(assembler, [
      {'text': '检查检查。', 'is_interim': false},
    ]);
    final revision = [
      {'text': '检查。', 'is_interim': false},
    ];
    expect(update(assembler, revision), '检查。');
    expect(update(assembler, revision), '检查。');
  });

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
