/// Bootstrap motifd inside WSL by running the same POSIX script used for SSH.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/settings.dart';
import '../ssh/ssh_bootstrapper_io.dart';

typedef WslScriptRunner =
    Future<WslScriptResult> Function({
      required String script,
      required String distribution,
      required Duration timeout,
    });

class WslScriptResult {
  const WslScriptResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int? exitCode;
  final String stdout;
  final String stderr;
}

class WslBootstrapper {
  WslBootstrapper({
    required this.server,
    this.repository = SshBootstrapper.defaultRepository,
    this.runTimeout = const Duration(minutes: 4),
    WslScriptRunner? scriptRunner,
  }) : _scriptRunner = scriptRunner ?? _runWithWslExe;

  final MotifServer server;
  final String repository;
  final Duration runTimeout;
  final WslScriptRunner _scriptRunner;

  Future<void> ensureMotifd() async {
    final distribution = server.wslDistribution.trim();
    final script = SshBootstrapper.buildScript(
      repository: repository,
      remoteHost: '127.0.0.1',
      remotePort: server.port,
      token: '',
    );

    final WslScriptResult result;
    try {
      result = await _scriptRunner(
        script: script,
        distribution: distribution,
        timeout: runTimeout,
      );
    } on WslBootstrapException catch (e) {
      throw _failure(
        e.stage,
        e.message,
        cause: e.cause,
        exitCode: e.exitCode,
        stdout: e.stdout,
        stderr: e.stderr,
      );
    } catch (e) {
      throw _failure(
        'starting wsl.exe',
        'WSL could not be started. Make sure WSL and the selected distribution '
            'are installed and initialized.',
        cause: e,
      );
    }

    if (!SshBootstrapper.bootstrapReady(
      exitCode: result.exitCode,
      stdout: result.stdout,
    )) {
      throw _failure(
        'running WSL bootstrap script',
        'The bootstrap script failed before motifd became ready.',
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    }
  }

  WslBootstrapException _failure(
    String stage,
    String reason, {
    Object? cause,
    int? exitCode,
    String? stdout,
    String? stderr,
  }) => WslBootstrapException(
    stage: stage,
    message: [
      'WSL initialize failed while $stage.',
      'Distribution: ${server.wslLabel}',
      'motifd target: 127.0.0.1:${server.port}',
      reason,
    ].join('\n'),
    cause: cause,
    exitCode: exitCode,
    stdout: stdout,
    stderr: stderr,
  );

  static Future<WslScriptResult> _runWithWslExe({
    required String script,
    required String distribution,
    required Duration timeout,
  }) async {
    final args = <String>[
      if (distribution.isNotEmpty) ...['--distribution', distribution],
      '--exec',
      'sh',
    ];
    final process = await Process.start('wsl.exe', args);
    final stdoutFuture = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderrFuture = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    process.stdin.write(script);
    await process.stdin.close();

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException catch (e) {
      process.kill();
      await process.exitCode.catchError((_) => -1);
      final output = await Future.wait([stdoutFuture, stderrFuture]);
      throw WslBootstrapException(
        stage: 'running WSL bootstrap script',
        message: 'WSL initialize timed out after ${_formatDuration(timeout)}.',
        cause: e,
        stdout: output[0],
        stderr: output[1],
      );
    }
    final output = await Future.wait([stdoutFuture, stderrFuture]);
    return WslScriptResult(
      exitCode: exitCode,
      stdout: output[0].trim(),
      stderr: output[1].trim(),
    );
  }

  static String _formatDuration(Duration duration) {
    if (duration.inMinutes >= 1 && duration.inSeconds % 60 == 0) {
      return '${duration.inMinutes}m';
    }
    if (duration.inSeconds >= 1) return '${duration.inSeconds}s';
    return '${duration.inMilliseconds}ms';
  }
}

class WslBootstrapException implements Exception {
  static const int _maxOutputChars = 4000;

  const WslBootstrapException({
    required this.stage,
    required this.message,
    this.cause,
    this.exitCode,
    this.stdout,
    this.stderr,
  });

  final String stage;
  final String message;
  final Object? cause;
  final int? exitCode;
  final String? stdout;
  final String? stderr;

  @override
  String toString() {
    final lines = <String>[message, 'Stage: $stage'];
    if (exitCode != null) lines.add('Exit code: $exitCode');
    if (cause != null) lines.add('Cause: $cause');
    final err = _tail(stderr);
    if (err != null) lines.add('stderr:\n$err');
    final out = _tail(stdout);
    if (out != null) lines.add('stdout:\n$out');
    return lines.join('\n');
  }

  static String? _tail(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.length <= _maxOutputChars) return trimmed;
    return '... output truncated ...\n'
        '${trimmed.substring(trimmed.length - _maxOutputChars)}';
  }
}
