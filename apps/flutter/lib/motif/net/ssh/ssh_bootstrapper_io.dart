/// Remote motifd bootstrap over SSH.
///
/// The bootstrap installs a user-local `motifd` binary from the latest GitHub
/// Release when needed, then starts it with `nohup` so it survives the SSH
/// session used to initialize it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../../models/settings.dart';

class SshBootstrapper {
  static const String defaultRepository = 'xiachufang/motif';

  SshBootstrapper({
    required this.server,
    this.repository = defaultRepository,
    this.connectTimeout = const Duration(seconds: 15),
    this.runTimeout = const Duration(minutes: 4),
  });

  final MotifServer server;
  final String repository;
  final Duration connectTimeout;
  final Duration runTimeout;

  Future<void> ensureMotifd() async {
    final socket = await _connect();
    final List<SSHKeyPair>? identities;
    try {
      identities = _identities();
    } catch (e) {
      socket.destroy();
      throw _failure(
        'preparing SSH credentials',
        'SSH private key could not be parsed. Check that the key and '
            'passphrase are correct.',
        cause: e,
      );
    }
    final client = SSHClient(
      socket,
      username: server.sshUsername.trim(),
      identities: identities,
      onPasswordRequest: _usesPassword ? () => server.sshPassword : null,
      onUserInfoRequest: _usesPassword
          ? (dynamic request) {
              final prompts = request.prompts as List<Object?>;
              return List<String>.filled(prompts.length, server.sshPassword);
            }
          : null,
    );
    try {
      try {
        await client.ping().timeout(connectTimeout);
      } on TimeoutException catch (e) {
        throw _failure(
          'authenticating SSH',
          'SSH authentication did not finish within '
              '${_formatDuration(connectTimeout)}.',
          cause: e,
        );
      } catch (e) {
        throw _failure(
          'authenticating SSH',
          'SSH authentication or keepalive failed.',
          cause: e,
        );
      }

      final result = await _runBootstrapScript(client);
      if (result.exitCode != 0) {
        throw _failure(
          'running remote bootstrap script',
          'Remote bootstrap script failed before motifd became ready.',
          exitCode: result.exitCode,
          exitSignal: result.exitSignal?.toString(),
          stdout: _decode(result.stdout),
          stderr: _decode(result.stderr),
        );
      }
    } finally {
      client.close();
    }
  }

  Future<SSHSocket> _connect() async {
    try {
      return await SSHSocket.connect(
        server.sshHost.trim(),
        server.sshPort,
        timeout: connectTimeout,
      );
    } on TimeoutException catch (e) {
      throw _failure(
        'connecting SSH',
        'SSH connection timed out after ${_formatDuration(connectTimeout)}.',
        cause: e,
      );
    } catch (e) {
      throw _failure('connecting SSH', 'SSH connection failed.', cause: e);
    }
  }

  Future<SSHRunResult> _runBootstrapScript(SSHClient client) async {
    try {
      return await client
          .runWithResult(
            buildScript(
              repository: repository,
              remoteHost: server.host.trim(),
              remotePort: server.port,
              token: server.token,
            ),
          )
          .timeout(runTimeout);
    } on TimeoutException catch (e) {
      throw _failure(
        'running remote bootstrap script',
        'Remote bootstrap script timed out after ${_formatDuration(runTimeout)}.',
        cause: e,
      );
    } catch (e) {
      throw _failure(
        'running remote bootstrap script',
        'Remote bootstrap command could not be executed.',
        cause: e,
      );
    }
  }

  SshBootstrapException _failure(
    String stage,
    String reason, {
    Object? cause,
    int? exitCode,
    String? exitSignal,
    String? stdout,
    String? stderr,
  }) {
    final user = server.sshUsername.trim();
    final sshUserHost = user.isEmpty
        ? server.sshHost.trim()
        : '$user@${server.sshHost.trim()}';
    final auth = switch (server.sshAuthMethod) {
      SshAuthMethod.password => 'password',
      SshAuthMethod.privateKey => 'private key',
    };
    return SshBootstrapException(
      stage: stage,
      message: [
        'SSH auto-initialize failed while $stage.',
        'SSH: $sshUserHost:${server.sshPort}',
        'Remote motifd target: ${server.host.trim()}:${server.port}',
        'Auth: $auth',
        reason,
      ].join('\n'),
      cause: cause,
      exitCode: exitCode,
      exitSignal: exitSignal,
      stdout: stdout,
      stderr: stderr,
    );
  }

  bool get _usesPassword => server.sshAuthMethod == SshAuthMethod.password;

  List<SSHKeyPair>? _identities() {
    if (server.sshAuthMethod != SshAuthMethod.privateKey) return null;
    final key = server.sshPrivateKey.trim();
    if (key.isEmpty) return null;
    return SSHKeyPair.fromPem(
      key,
      server.sshPrivateKeyPassphrase.isEmpty
          ? null
          : server.sshPrivateKeyPassphrase,
    );
  }

  static String buildScript({
    required String repository,
    required String remoteHost,
    required int remotePort,
    required String token,
  }) {
    final qRepository = _shQuote(repository);
    final qHost = _shQuote(remoteHost);
    final qPort = _shQuote('$remotePort');
    final qToken = _shQuote(token);
    return '''
set -eu

REPOSITORY=$qRepository
REMOTE_HOST=$qHost
REMOTE_PORT=$qPort
TOKEN_VALUE=$qToken

DATA_HOME=\${XDG_DATA_HOME:-"\$HOME/.local/share"}
STATE_HOME=\${XDG_STATE_HOME:-"\$HOME/.local/state"}
DATA_DIR="\$DATA_HOME/motif"
STATE_DIR="\$STATE_HOME/motif"
BIN_DIR="\$DATA_DIR/bin"
BIN="\$BIN_DIR/motifd"
TOKEN_FILE="\$DATA_DIR/motifd/token"
PID_FILE="\$STATE_DIR/motifd.pid"
LOG_FILE="\$STATE_DIR/motifd.log"
LISTEN="\$REMOTE_HOST:\$REMOTE_PORT"

download_to() {
  url="\$1"
  out="\$2"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "\$url" -o "\$out"; then
      return 0
    else
      code=\$?
      echo "curl failed to download \$url (exit \$code)" >&2
      return "\$code"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO "\$out" "\$url"; then
      return 0
    else
      code=\$?
      echo "wget failed to download \$url (exit \$code)" >&2
      return "\$code"
    fi
  else
    echo "curl or wget is required to download motifd" >&2
    return 127
  fi
}

ping_motifd() {
  url="http://\$REMOTE_HOST:\$REMOTE_PORT/ping"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "\$url" 2>/dev/null | grep -q '"service":"motif-server"'
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- -T 2 "\$url" 2>/dev/null | grep -q '"service":"motif-server"'
  else
    return 1
  fi
}

install_motifd() {
  os=\$(uname -s | tr '[:upper:]' '[:lower:]')
  case "\$os" in
    linux) platform=linux ;;
    darwin) platform=macos ;;
    *) echo "unsupported remote OS: \$os" >&2; exit 20 ;;
  esac
  machine=\$(uname -m)
  case "\$machine" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) echo "unsupported remote arch: \$machine" >&2; exit 21 ;;
  esac
  echo "remote platform: \$platform-\$arch"

  tmp=\$(mktemp -d)
  trap 'rm -rf "\$tmp"' EXIT HUP INT TERM
  api="https://api.github.com/repos/\$REPOSITORY/releases/latest"
  echo "downloading release metadata from \$api"
  download_to "\$api" "\$tmp/release.json"
  asset_url=\$(
    tr '{}[],' '\\n\\n\\n\\n' < "\$tmp/release.json" |
      sed -n "s|.*\\"browser_download_url\\"[[:space:]]*:[[:space:]]*\\"\\([^\\"]*motifd-[^\\"]*-\$platform-\$arch\\.tar\\.gz\\)\\".*|\\1|p" |
      head -n 1
  )
  if [ -z "\$asset_url" ]; then
    echo "latest release has no motifd asset for \$platform-\$arch" >&2
    exit 22
  fi
  echo "downloading motifd asset from \$asset_url"
  download_to "\$asset_url" "\$tmp/motifd.tar.gz"
  echo "extracting motifd archive"
  tar -xzf "\$tmp/motifd.tar.gz" -C "\$tmp"
  found=\$(find "\$tmp" -type f -name motifd -print | head -n 1)
  if [ -z "\$found" ]; then
    echo "downloaded motifd archive did not contain motifd" >&2
    exit 23
  fi
  cp "\$found" "\$BIN"
  chmod 0755 "\$BIN"
  echo "installed motifd at \$BIN"
}

echo "checking motifd on \$LISTEN"
if ping_motifd; then
  echo "motifd already running on \$LISTEN"
  exit 0
fi

mkdir -p "\$BIN_DIR" "\$STATE_DIR" "\$(dirname "\$TOKEN_FILE")"

version_check_err="\$STATE_DIR/motifd-version-check.err"
needs_install=0
if [ ! -x "\$BIN" ]; then
  needs_install=1
elif "\$BIN" --version >/dev/null 2>"\$version_check_err"; then
  rm -f "\$version_check_err"
else
  echo "installed motifd failed version check; reinstalling" >&2
  cat "\$version_check_err" >&2 2>/dev/null || true
  needs_install=1
fi

if [ "\$needs_install" -eq 1 ]; then
  install_motifd
fi

if [ -n "\$TOKEN_VALUE" ]; then
  echo "writing motifd token file at \$TOKEN_FILE"
  umask 077
  printf '%s\\n' "\$TOKEN_VALUE" > "\$TOKEN_FILE"
fi

if [ -f "\$PID_FILE" ]; then
  old_pid=\$(cat "\$PID_FILE" 2>/dev/null || true)
  if [ -n "\$old_pid" ] && kill -0 "\$old_pid" 2>/dev/null && ping_motifd; then
    echo "motifd already running on \$LISTEN"
    exit 0
  fi
fi

if [ -n "\$TOKEN_VALUE" ]; then
  echo "starting motifd on \$LISTEN with token file; log: \$LOG_FILE"
  nohup "\$BIN" --listen "\$LISTEN" --token-file "\$TOKEN_FILE" >>"\$LOG_FILE" 2>&1 </dev/null &
else
  echo "starting motifd on \$LISTEN; log: \$LOG_FILE"
  nohup "\$BIN" --listen "\$LISTEN" >>"\$LOG_FILE" 2>&1 </dev/null &
fi
pid=\$!
printf '%s\\n' "\$pid" > "\$PID_FILE"

i=0
while [ "\$i" -lt 30 ]; do
  if ping_motifd; then
    echo "motifd started on \$LISTEN"
    exit 0
  fi
  if ! kill -0 "\$pid" 2>/dev/null; then
    echo "motifd exited during startup; log follows" >&2
    tail -n 80 "\$LOG_FILE" >&2 2>/dev/null || true
    exit 24
  fi
  i=\$((i + 1))
  sleep 1
done

echo "motifd did not become ready on \$LISTEN; log follows" >&2
tail -n 80 "\$LOG_FILE" >&2 2>/dev/null || true
exit 25
''';
  }

  static String _shQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";

  static String _decode(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true).trim();

  static String _formatDuration(Duration duration) {
    if (duration.inMinutes >= 1 && duration.inSeconds % 60 == 0) {
      return '${duration.inMinutes}m';
    }
    if (duration.inSeconds >= 1) return '${duration.inSeconds}s';
    return '${duration.inMilliseconds}ms';
  }
}

class SshBootstrapException implements Exception {
  static const int _maxOutputChars = 4000;

  const SshBootstrapException({
    required this.stage,
    required this.message,
    this.cause,
    this.exitCode,
    this.exitSignal,
    this.stdout,
    this.stderr,
  });

  final String stage;
  final String message;
  final Object? cause;
  final int? exitCode;
  final String? exitSignal;
  final String? stdout;
  final String? stderr;

  @override
  String toString() {
    final lines = <String>[message, 'Stage: $stage'];
    if (exitCode != null) lines.add('Exit code: $exitCode');
    if (exitSignal != null && exitSignal!.isNotEmpty) {
      lines.add('Exit signal: $exitSignal');
    }
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
