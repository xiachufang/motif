import 'dart:math';

const sessionNameAdjectives = <String>[
  'brave',
  'bright',
  'calm',
  'clever',
  'cozy',
  'eager',
  'gentle',
  'happy',
  'lively',
  'lucky',
  'mellow',
  'nimble',
  'quiet',
  'shiny',
  'sunny',
  'witty',
];

const sessionNameFruits = <String>[
  'apple',
  'apricot',
  'banana',
  'cherry',
  'coconut',
  'fig',
  'grape',
  'guava',
  'kiwi',
  'lemon',
  'mango',
  'melon',
  'orange',
  'papaya',
  'peach',
  'plum',
];

String generateSessionName({
  Iterable<String> existingNames = const <String>[],
  Random? random,
}) {
  final existing = existingNames.map((name) => name.toLowerCase()).toSet();
  final rng = random ?? Random();
  final maxAttempts = sessionNameAdjectives.length * sessionNameFruits.length;

  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final candidate =
        '${sessionNameAdjectives[rng.nextInt(sessionNameAdjectives.length)]}'
        '-${sessionNameFruits[rng.nextInt(sessionNameFruits.length)]}';
    if (!existing.contains(candidate)) return candidate;
  }

  for (final adjective in sessionNameAdjectives) {
    for (final fruit in sessionNameFruits) {
      final candidate = '$adjective-$fruit';
      if (!existing.contains(candidate)) return candidate;
    }
  }

  for (var suffix = 2; ; suffix++) {
    final candidate =
        '${sessionNameAdjectives.first}-${sessionNameFruits.first}-$suffix';
    if (!existing.contains(candidate)) return candidate;
  }
}
