// Adapted from rhinoc/douvo at d68cf190 (MIT).
// See DOUVO_LICENSE.txt in this directory.
import 'dart:math';

import 'package:characters/characters.dart';

class DoubaoRecognitionSegment {
  const DoubaoRecognitionSegment({
    required this.id,
    required this.text,
    required this.isFinal,
    this.index,
    this.start,
    this.end,
  });

  final String id;
  final String text;
  final bool isFinal;
  final int? index;
  final int? start;
  final int? end;

  DoubaoRecognitionSegment withId(String id) => DoubaoRecognitionSegment(
    id: id,
    text: text,
    isFinal: isFinal,
    index: index,
    start: start,
    end: end,
  );
}

class DoubaoRecognitionResult {
  const DoubaoRecognitionResult({
    required this.segments,
    required this.isFinal,
    required this.isCumulative,
  });

  final List<DoubaoRecognitionSegment> segments;
  final bool isFinal;
  final bool isCumulative;
  String get text => _join(segments.map((segment) => segment.text));

  static DoubaoRecognitionResult? parse(Map<String, Object?> json) {
    final raw = json['results'];
    if (raw is! List) return null;
    final results = raw.whereType<Map>().toList();
    if (results.isEmpty) return null;
    final cumulative = _isCumulative(results);
    final visible = cumulative ? results.take(1) : results;
    final segments = <DoubaoRecognitionSegment>[];
    for (final result in visible) {
      final text = _text(result);
      if (text.isEmpty) continue;
      final index = _int(result['index']);
      final start = _int(result['start_time']);
      final end = _int(result['end_time']);
      segments.add(
        DoubaoRecognitionSegment(
          id: start != null
              ? 'start:$start'
              : index != null
              ? 'index:$index'
              : end != null
              ? 'end:$end'
              : 'ordinal:${segments.length}',
          text: text,
          index: index,
          start: start,
          end: end,
          isFinal: result['is_interim'] == false,
        ),
      );
    }
    // Sentence detail flags cannot finalize the cumulative stream. Conversely,
    // last_post_process can finalize it without an is_vad_finished flag.
    final nonstream = visible.any((result) {
      final extra = result['extra'];
      return extra is Map && extra['nonstream_result'] == true;
    });
    return DoubaoRecognitionResult(
      segments: segments,
      isFinal: nonstream || visible.every((r) => r['is_interim'] == false),
      isCumulative: cumulative,
    );
  }

  static bool _isCumulative(List<Map> results) {
    if (results.length < 2 || _text(results.first).isEmpty) return false;
    final details = results.skip(1);
    final texts = details.map(_text).where((text) => text.isNotEmpty).toList();
    if (texts.isEmpty) return false;
    String normalize(String value) => value.replaceAll(RegExp(r'\s+'), '');
    if (normalize(_join(texts)) == normalize(_text(results.first))) return true;
    return _int(results.first['start_time']) == 0 &&
        details.any((result) {
          final extra = result['extra'];
          return result.containsKey('stream_asr_finish') ||
              (extra is Map && extra.containsKey('nonstream_result'));
        });
  }

  static String _text(Map result) => switch (result['text']) {
    String value => value.trim(),
    _ => '',
  };

  static int? _int(Object? value) => switch (value) {
    num value when value.isFinite => value.toInt(),
    String value => int.tryParse(value),
    _ => null,
  };
}

/// Mirrors Douvo's active-window assembler. A cumulative frame switches the
/// entire session to snapshots, including subsequent single-result revisions.
class DoubaoTranscriptAssembler {
  final List<DoubaoRecognitionSegment> _committed = [];
  DoubaoRecognitionSegment? _active;
  bool _cumulative = false;
  String _text = '';
  String get text => _text;

  void reset() {
    _committed.clear();
    _active = null;
    _cumulative = false;
    _text = '';
  }

  String update(DoubaoRecognitionResult result) {
    if (result.segments.isEmpty) return _text;
    if (result.isCumulative) {
      _cumulative = true;
      _committed.clear();
      _active = null;
    }
    if (_cumulative) return _text = result.text;
    // Legacy results can contain several untimed text pieces. Keep their joined
    // text as one candidate; the window algorithm cannot order those pieces by
    // audio time and would otherwise replace one with another.
    final untimedBatch =
        result.segments.length > 1 &&
        result.segments.every(
          (segment) => segment.start == null && segment.end == null,
        );
    final sorted = untimedBatch
        ? [
            DoubaoRecognitionSegment(
              id: result.segments.first.id,
              text: result.text,
              isFinal: result.isFinal,
              index: result.segments.first.index,
            ),
          ]
        : ([...result.segments]..sort(_compare));
    for (final incoming in sorted) {
      // Final results can be replayed or revised after the next window starts.
      // Resolve those against committed windows before touching the active one,
      // otherwise they are appended again (and can displace the active text).
      final committedIndex = _committed.indexWhere(
        (segment) =>
            _sameTimeline(segment, incoming) &&
            (segment.id == incoming.id ||
                (segment.end == incoming.end && _overlaps(segment, incoming))),
      );
      if (committedIndex != -1) {
        final existing = _committed[committedIndex];
        // A late interim must not undo a final correction. Windows committed
        // merely because a newer window started may still accept revisions.
        if (incoming.isFinal || !existing.isFinal) {
          _committed[committedIndex] = incoming.withId(existing.id);
        }
        continue;
      }
      final active = _active;
      if (active == null) {
        if (incoming.isFinal) {
          _committed.add(incoming);
        } else {
          _active = incoming;
        }
        continue;
      }
      final overlap =
          _sameTimeline(active, incoming) && _overlaps(active, incoming);
      if (overlap &&
          incoming.start! > active.start! &&
          incoming.end! > active.end!) {
        final merged = DoubaoRecognitionSegment(
          id: active.id,
          text: _mergeSliding(active.text, incoming.text),
          index: active.index ?? incoming.index,
          start: active.start,
          end: incoming.end,
          isFinal: incoming.isFinal,
        );
        if (incoming.isFinal) {
          _committed.add(merged);
          _active = null;
        } else {
          _active = merged;
        }
      } else if (active.id == incoming.id || overlap) {
        if (incoming.isFinal) {
          final preferred =
              incoming.start == active.start ||
                  incoming.text.characters.length * 10 >=
                      active.text.characters.length * 6
              ? incoming
              : active;
          _committed.add(preferred.withId(active.id));
          _active = null;
        } else {
          _active = _preferredActive(active, incoming).withId(active.id);
        }
      } else if (active.end != null &&
          incoming.start != null &&
          incoming.start! >= active.end!) {
        _committed.add(active);
        if (incoming.isFinal) {
          _committed.add(incoming);
          _active = null;
        } else {
          _active = incoming;
        }
      } else if (incoming.isFinal) {
        if (active.text.characters.length >
            incoming.text.characters.length * 2) {
          _committed.add(active);
        }
        _committed.add(incoming);
        _active = null;
      } else {
        _active = _preferredActive(active, incoming);
      }
    }
    return _text = _join([
      ..._committed.map((segment) => segment.text),
      if (_active != null) _active!.text,
    ]);
  }

  static DoubaoRecognitionSegment _preferredActive(
    DoubaoRecognitionSegment existing,
    DoubaoRecognitionSegment incoming,
  ) =>
      existing.isFinal ||
          incoming.text.characters.length < existing.text.characters.length
      ? existing
      : incoming;

  static bool _sameTimeline(
    DoubaoRecognitionSegment a,
    DoubaoRecognitionSegment b,
  ) => a.index == null || b.index == null || a.index == b.index;

  static bool _overlaps(
    DoubaoRecognitionSegment a,
    DoubaoRecognitionSegment b,
  ) {
    if (a.start == null ||
        a.end == null ||
        b.start == null ||
        b.end == null ||
        a.end! <= a.start! ||
        b.end! <= b.start!) {
      return false;
    }
    final overlap = min(a.end!, b.end!) - max(a.start!, b.start!);
    return overlap > 0 &&
        overlap * 2 >= min(a.end! - a.start!, b.end! - b.start!);
  }

  static int _compare(DoubaoRecognitionSegment a, DoubaoRecognitionSegment b) {
    for (final pair in [
      (a.index, b.index),
      (a.start, b.start),
      (a.end, b.end),
    ]) {
      if (pair.$1 != null && pair.$2 != null && pair.$1 != pair.$2) {
        return pair.$1!.compareTo(pair.$2!);
      }
    }
    return a.id.compareTo(b.id);
  }

  static String _mergeSliding(String existing, String incoming) {
    if (existing.contains(incoming)) return existing;
    if (incoming.contains(existing)) return incoming;
    final left = existing.characters.toList();
    final right = incoming.characters.toList();
    for (
      var overlap = min(left.length, right.length);
      overlap >= 4;
      overlap--
    ) {
      if (left.skip(left.length - overlap).join() ==
          right.take(overlap).join()) {
        return existing + right.skip(overlap).join();
      }
    }
    return _append(existing, incoming);
  }
}

String _join(Iterable<String> texts) => texts.fold('', _append);

String _append(String output, String segment) {
  if (output.isEmpty || segment.isEmpty) return output + segment;
  final last = output.characters.last;
  final first = segment.characters.first;
  bool isCjk(String character) => character.runes.any(
    (rune) =>
        (rune >= 0x3400 && rune <= 0x4dbf) ||
        (rune >= 0x4e00 && rune <= 0x9fff) ||
        (rune >= 0xf900 && rune <= 0xfaff),
  );
  if (last.trim().isEmpty ||
      first.trim().isEmpty ||
      '。！？.!?'.contains(last) ||
      (isCjk(last) && isCjk(first))) {
    return output + segment;
  }
  return '$output $segment';
}
