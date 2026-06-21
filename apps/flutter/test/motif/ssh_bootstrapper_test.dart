import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/ssh/ssh_bootstrapper.dart';

void main() {
  group('SshBootstrapException', () {
    test('includes remote failure details and truncates long output', () {
      final longStdout = '${List.filled(5000, 'a').join()}tail-marker';
      const stderr = 'motifd exited during startup\nbind: address in use';
      final error = SshBootstrapException(
        stage: 'running remote bootstrap script',
        message:
            'SSH auto-initialize failed while running remote bootstrap script.\n'
            'SSH: fei@bastion.example.com:22\n'
            'Remote motifd target: 127.0.0.1:7777\n'
            'Auth: password\n'
            'Remote bootstrap script failed before motifd became ready.',
        exitCode: 24,
        stdout: longStdout,
        stderr: stderr,
      ).toString();

      expect(error, contains('Stage: running remote bootstrap script'));
      expect(error, contains('Exit code: 24'));
      expect(error, contains('stderr:\n$stderr'));
      expect(error, contains('stdout:\n... output truncated ...'));
      expect(error, contains('tail-marker'));
    });
  });

  group('SshBootstrapper.bootstrapReady', () {
    test('a zero exit code is success', () {
      expect(
        SshBootstrapper.bootstrapReady(exitCode: 0, stdout: ''),
        isTrue,
      );
    });

    test('a null exit code is success when motifd is already running', () {
      // dartssh2 can report a null exit code on a clean exit; the readiness
      // marker in stdout is the source of truth then.
      expect(
        SshBootstrapper.bootstrapReady(
          exitCode: null,
          stdout: 'checking motifd on 127.0.0.1:7777\n'
              'motifd already running on 127.0.0.1:7777',
        ),
        isTrue,
      );
    });

    test('a null exit code is success when motifd just started', () {
      expect(
        SshBootstrapper.bootstrapReady(
          exitCode: null,
          stdout: 'starting motifd on 127.0.0.1:7777; log: ...\n'
              'motifd started on 127.0.0.1:7777',
        ),
        isTrue,
      );
    });

    test('a null exit code with no readiness marker is a failure', () {
      expect(
        SshBootstrapper.bootstrapReady(exitCode: null, stdout: ''),
        isFalse,
      );
    });

    test('a non-zero exit code is always a failure', () {
      expect(
        SshBootstrapper.bootstrapReady(
          exitCode: 24,
          stdout: 'motifd already running on 127.0.0.1:7777',
        ),
        isFalse,
      );
    });
  });

  group('SshBootstrapper script', () {
    test('prints progress messages for remote diagnostics', () {
      final script = SshBootstrapper.buildScript(
        repository: 'xiachufang/motif',
        remoteHost: '127.0.0.1',
        remotePort: 7777,
        token: '',
      );

      expect(script, contains(r'checking motifd on $LISTEN'));
      expect(script, contains(r'remote platform: $platform-$arch'));
      expect(script, contains(r'downloading release metadata from $api'));
      expect(script, contains(r'starting motifd on $LISTEN'));
    });
  });
}
