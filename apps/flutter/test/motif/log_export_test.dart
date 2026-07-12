import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/log/log_export.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  test(
    'falls back when the preferred export directory cannot be created',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'motif-log-export-test.',
      );
      final blocked = File('${root.path}/not-a-directory');
      final support = Directory('${root.path}/support');
      final temp = Directory('${root.path}/tmp');
      final calls = <String>[];

      await blocked.writeAsString('blocked');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProviderChannel,
        (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'getApplicationSupportDirectory' => support.path,
            'getDownloadsDirectory' => '${blocked.path}/Downloads',
            'getTemporaryDirectory' => temp.path,
            _ => null,
          };
        },
      );

      addTearDown(() async {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pathProviderChannel,
          null,
        );
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final result = await exportLogFiles();

      expect(result.path, startsWith(temp.path));
      expect(result.sourceCount, 0);
      expect(
        calls,
        containsAllInOrder(<String>[
          'getApplicationSupportDirectory',
          if (Platform.isMacOS) 'getDownloadsDirectory',
          'getTemporaryDirectory',
        ]),
      );
      expect(
        File(result.path).readAsString(),
        completion(contains('No Motif log files found.')),
      );
    },
  );
}
