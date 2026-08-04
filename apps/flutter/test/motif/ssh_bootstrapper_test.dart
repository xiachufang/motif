import 'dart:convert';
import 'dart:io';

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
      expect(SshBootstrapper.bootstrapReady(exitCode: 0, stdout: ''), isTrue);
    });

    test('a null exit code is success when motifd is already running', () {
      // dartssh2 can report a null exit code on a clean exit; the readiness
      // marker in stdout is the source of truth then.
      expect(
        SshBootstrapper.bootstrapReady(
          exitCode: null,
          stdout:
              'checking motifd on 127.0.0.1:7777\n'
              'motifd already running on 127.0.0.1:7777',
        ),
        isTrue,
      );
    });

    test('a null exit code is success when motifd just started', () {
      expect(
        SshBootstrapper.bootstrapReady(
          exitCode: null,
          stdout:
              'starting motifd on 127.0.0.1:7777; log: ...\n'
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
      expect(
        script,
        contains(r'downloading stable motifd metadata from $METADATA_URL'),
      );
      expect(script, contains(r'starting motifd on $LISTEN'));
      expect(script, contains('MOTIFD_REMOTE_DOWNLOAD_FAILED'));
      expect(script, contains(r'"$platform" "$arch" "$upload_path"'));
      expect(script, contains('verify_sha256'));
    });

    test('force install script restarts the managed remote process', () {
      final script = SshBootstrapper.buildScript(
        repository: 'xiachufang/motif',
        remoteHost: '127.0.0.1',
        remotePort: 7777,
        token: '',
        forceInstall: true,
      );

      expect(script, contains('FORCE_INSTALL=1'));
      expect(script, contains(r'stopping motifd process $old_pid for update'));
      expect(script, contains(r'mv -f "$version_tmp" "$VERSION_FILE"'));
    });

    test('installs an archive uploaded by the SSH client', () {
      final script = SshBootstrapper.buildScript(
        repository: 'xiachufang/motif',
        remoteHost: '127.0.0.1',
        remotePort: 7777,
        token: '',
        uploadedArchive: "/home/fei/motif's upload.tar.gz",
        uploadedVersion: '1.2.3',
      );

      expect(
        script,
        contains("UPLOADED_ARCHIVE='/home/fei/motif'\"'\"'s upload.tar.gz'"),
      );
      expect(script, contains('installing motifd asset uploaded over SSH'));
      expect(script, contains(r'rm -f "$UPLOADED_ARCHIVE"'));
    });

    test('is valid POSIX shell syntax', () async {
      if (Platform.isWindows) return;
      final script = SshBootstrapper.buildScript(
        repository: 'xiachufang/motif',
        remoteHost: '127.0.0.1',
        remotePort: 7777,
        token: '',
      );
      final process = await Process.start('sh', const <String>['-n']);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      process.stdin.write(script);
      await process.stdin.close();

      expect(await process.exitCode, 0, reason: await stderr);
      expect(await stdout, isEmpty);
    });

    test('version inspection script is valid POSIX shell syntax', () async {
      if (Platform.isWindows) return;
      final script = SshBootstrapper.buildVersionInspectionScript(
        remoteHost: "host's-loopback",
        remotePort: 7777,
      );
      final process = await Process.start('sh', const <String>['-n']);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      process.stdin.write(script);
      await process.stdin.close();

      expect(await process.exitCode, 0, reason: await stderr);
      expect(await stdout, isEmpty);
      expect(script, contains('http://\$REMOTE_HOST:\$REMOTE_PORT/ping'));
    });
  });

  group('SshBootstrapper local download fallback', () {
    test('recognizes an explicit remote download failure marker', () {
      expect(
        SshBootstrapper.shouldUseLocalDownloadFallback(
          stdout: 'remote platform: linux-x86_64',
          stderr:
              'curl failed\n'
              'MOTIFD_REMOTE_DOWNLOAD_FAILED platform=linux arch=x86_64 '
              'upload=/home/fei/.local/share/motif/bin/'
              'motifd-linux-x86_64-upload.tar.gz',
        ),
        isTrue,
      );
    });

    test('does not retry unrelated remote bootstrap failures', () {
      expect(
        SshBootstrapper.shouldUseLocalDownloadFallback(
          stdout: 'starting motifd',
          stderr: 'bind: address already in use',
        ),
        isFalse,
      );
    });

    test('selects the matching motifd release archive', () {
      final asset = SshBootstrapper.releaseAsset(
        <String, Object?>{
          'schema': 1,
          'channel': 'stable',
          'product': 'motifd',
          'assets': <String, Object?>{
            'linux-x86_64': <String, Object?>{
              'version': '1.2.3',
              'file': 'motifd-1.2.3-linux-x86_64.tar.gz',
              'url':
                  'https://github.com/xiachufang/motif/releases/download/'
                  'v1.2.3/motifd-1.2.3-linux-x86_64.tar.gz',
              'sha256': List.filled(64, 'a').join(),
              'size': 123,
            },
          },
        },
        platform: 'linux',
        arch: 'x86_64',
      );

      expect(
        asset?.url.toString(),
        'https://github.com/xiachufang/motif/releases/download/'
        'v1.2.3/motifd-1.2.3-linux-x86_64.tar.gz',
      );
      expect(asset?.sha256, List.filled(64, 'a').join());
      expect(asset?.size, 123);
      expect(asset?.version, '1.2.3');
    });

    test('rejects non-HTTPS release asset URLs', () {
      expect(
        SshBootstrapper.releaseAsset(
          <String, Object?>{
            'schema': 1,
            'channel': 'stable',
            'product': 'motifd',
            'assets': <String, Object?>{
              'linux-x86_64': <String, Object?>{
                'version': '1.2.3',
                'file': 'motifd-1.2.3-linux-x86_64.tar.gz',
                'url': 'http://example.com/motifd.tar.gz',
                'sha256': List.filled(64, 'a').join(),
                'size': 123,
              },
            },
          },
          platform: 'linux',
          arch: 'x86_64',
        ),
        isNull,
      );
    });
  });

  group('SshMotifdVersionInfo', () {
    test('offers an update when the stable remote asset is newer', () {
      final info = SshMotifdVersionInfo.evaluate(
        serverVersion: '1.0.54',
        localVersion: '1.0.55+38',
        availableVersion: '1.0.55',
      );

      expect(info.serverVersion, '1.0.54');
      expect(info.localVersion, '1.0.55');
      expect(info.availableVersion, '1.0.55');
      expect(info.updateAvailable, isTrue);
    });

    test('does not offer an update when the server is current', () {
      final info = SshMotifdVersionInfo.evaluate(
        serverVersion: '1.0.55',
        localVersion: '1.0.55',
        availableVersion: '1.0.55',
      );

      expect(info.updateAvailable, isFalse);
    });
  });
}
