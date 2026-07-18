import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/ssh/ssh_bootstrapper.dart';
import 'package:motif/motif/net/wsl/wsl_bootstrapper.dart';

void main() {
  const server = MotifServer(
    id: 'wsl',
    name: 'Ubuntu',
    host: '127.0.0.1',
    port: 17777,
    kind: ServerKind.wsl,
    wslDistribution: 'Ubuntu-24.04',
  );

  test(
    'runs the SSH bootstrap script inside the selected distribution',
    () async {
      String? capturedScript;
      String? capturedDistribution;
      final bootstrapper = WslBootstrapper(
        server: server,
        scriptRunner:
            ({required script, required distribution, required timeout}) async {
              capturedScript = script;
              capturedDistribution = distribution;
              return const WslScriptResult(
                exitCode: 0,
                stdout: 'motifd started on 127.0.0.1:17777',
                stderr: '',
              );
            },
      );

      await bootstrapper.ensureMotifd();

      expect(capturedDistribution, 'Ubuntu-24.04');
      expect(
        capturedScript,
        SshBootstrapper.buildScript(
          repository: SshBootstrapper.defaultRepository,
          remoteHost: '127.0.0.1',
          remotePort: 17777,
          token: '',
        ),
      );
      expect(capturedScript, contains(r'${XDG_DATA_HOME'));
      expect(capturedScript, contains('/releases/latest'));
      expect(capturedScript, contains(r'nohup "$BIN" --listen "$LISTEN"'));
    },
  );

  test('reports bootstrap output when motifd does not become ready', () async {
    final bootstrapper = WslBootstrapper(
      server: server,
      scriptRunner:
          ({required script, required distribution, required timeout}) async =>
              const WslScriptResult(
                exitCode: 24,
                stdout: 'starting motifd on 127.0.0.1:17777',
                stderr: 'bind: address already in use',
              ),
    );

    await expectLater(
      bootstrapper.ensureMotifd(),
      throwsA(
        isA<WslBootstrapException>()
            .having((e) => e.toString(), 'details', contains('Exit code: 24'))
            .having(
              (e) => e.toString(),
              'stderr',
              contains('bind: address already in use'),
            )
            .having(
              (e) => e.toString(),
              'distribution',
              contains('Ubuntu-24.04'),
            ),
      ),
    );
  });
}
