/// Remote motifd bootstrap over SSH.
///
/// The bootstrap installs a user-local `motifd` binary from the per-platform
/// stable release manifest when needed, then starts it with `nohup` so it
/// survives the SSH session used to initialize it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:http/http.dart' as http;

import '../../models/settings.dart';

class SshBootstrapper {
  static const String defaultRepository = 'xiachufang/motif';

  SshBootstrapper({
    required this.server,
    this.repository = defaultRepository,
    this.connectTimeout = const Duration(seconds: 15),
    this.runTimeout = const Duration(minutes: 4),
    this.httpClient,
    Uri? metadataUrl,
  }) : metadataUrl = metadataUrl ?? stableMetadataUrl(repository);

  final MotifServer server;
  final String repository;
  final Duration connectTimeout;
  final Duration runTimeout;
  final http.Client? httpClient;
  final Uri metadataUrl;

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
      final stdout = _decode(result.stdout);
      if (bootstrapReady(exitCode: result.exitCode, stdout: stdout)) return;

      final stderr = _decode(result.stderr);
      final localUpload = _localUploadRequest(stdout: stdout, stderr: stderr);
      if (localUpload != null) {
        await _retryWithLocalDownload(
          client,
          localUpload,
          initialResult: result,
          initialStdout: stdout,
          initialStderr: stderr,
        );
        return;
      }

      throw _failure(
        'running remote bootstrap script',
        'Remote bootstrap script failed before motifd became ready.',
        exitCode: result.exitCode,
        exitSignal: result.exitSignal?.toString(),
        stdout: stdout,
        stderr: stderr,
      );
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

  Future<SSHRunResult> _runBootstrapScript(
    SSHClient client, {
    String uploadedArchive = '',
  }) async {
    try {
      return await client
          .runWithResult(
            buildScript(
              repository: repository,
              remoteHost: server.host.trim(),
              remotePort: server.port,
              token: server.token,
              metadataUrl: metadataUrl.toString(),
              uploadedArchive: uploadedArchive,
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

  Future<void> _retryWithLocalDownload(
    SSHClient client,
    _LocalUploadRequest request, {
    required SSHRunResult initialResult,
    required String initialStdout,
    required String initialStderr,
  }) async {
    final Uint8List archive;
    try {
      archive = await _downloadReleaseArchive(
        platform: request.platform,
        arch: request.arch,
      );
    } catch (e) {
      throw _failure(
        'downloading motifd locally',
        'The SSH server could not download motifd, and the local fallback '
            'download also failed.',
        cause: e,
        exitCode: initialResult.exitCode,
        exitSignal: initialResult.exitSignal?.toString(),
        stdout: initialStdout,
        stderr: initialStderr,
      );
    }

    try {
      await _uploadReleaseArchive(client, request.uploadPath, archive);
    } catch (e) {
      throw _failure(
        'uploading motifd over SSH',
        'motifd was downloaded locally, but its archive could not be '
            'uploaded to the SSH server.',
        cause: e,
        exitCode: initialResult.exitCode,
        exitSignal: initialResult.exitSignal?.toString(),
        stdout: initialStdout,
        stderr: initialStderr,
      );
    }

    final retry = await _runBootstrapScript(
      client,
      uploadedArchive: request.uploadPath,
    );
    final retryStdout = _decode(retry.stdout);
    if (bootstrapReady(exitCode: retry.exitCode, stdout: retryStdout)) return;

    throw _failure(
      'starting motifd after SSH upload',
      'The locally downloaded motifd archive was uploaded, but the remote '
          'bootstrap still failed before motifd became ready.',
      exitCode: retry.exitCode,
      exitSignal: retry.exitSignal?.toString(),
      stdout: retryStdout,
      stderr: _decode(retry.stderr),
    );
  }

  Future<Uint8List> _downloadReleaseArchive({
    required String platform,
    required String arch,
  }) async {
    final client = httpClient ?? http.Client();
    final ownsClient = httpClient == null;
    try {
      final metadata = await client
          .get(metadataUrl, headers: _metadataHeaders)
          .timeout(connectTimeout);
      if (metadata.statusCode != 200) {
        throw StateError(
          'Stable motifd metadata returned HTTP ${metadata.statusCode}',
        );
      }

      final asset = releaseAsset(
        jsonDecode(utf8.decode(metadata.bodyBytes)),
        platform: platform,
        arch: arch,
      );
      if (asset == null) {
        throw StateError(
          'Stable metadata has no motifd asset for $platform-$arch',
        );
      }

      final response = await client
          .get(asset.url, headers: _assetHeaders)
          .timeout(runTimeout);
      if (response.statusCode != 200) {
        throw StateError(
          'motifd release asset returned HTTP ${response.statusCode}',
        );
      }
      if (response.bodyBytes.isEmpty) {
        throw StateError('motifd release asset was empty');
      }
      if (response.bodyBytes.length != asset.size) {
        throw StateError(
          'motifd release asset size mismatch: expected ${asset.size}, '
          'received ${response.bodyBytes.length}',
        );
      }
      final actualSha256 = sha256.convert(response.bodyBytes).toString();
      if (actualSha256 != asset.sha256) {
        throw StateError('motifd release asset SHA-256 mismatch');
      }
      return response.bodyBytes;
    } finally {
      if (ownsClient) client.close();
    }
  }

  Future<void> _uploadReleaseArchive(
    SSHClient client,
    String remotePath,
    Uint8List archive,
  ) async {
    await (() async {
      final sftp = await client.sftp();
      final file = await sftp.open(
        remotePath,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        // Bound the number of in-flight SFTP writes. motifd archives can be
        // large enough that writeBytes on the entire buffer would enqueue
        // thousands of requests at once.
        const chunkSize = 512 * 1024;
        for (var offset = 0; offset < archive.length; offset += chunkSize) {
          final end = (offset + chunkSize < archive.length)
              ? offset + chunkSize
              : archive.length;
          await file.writeBytes(
            Uint8List.sublistView(archive, offset, end),
            offset: offset,
          );
        }
      } finally {
        await file.close();
      }
    })().timeout(runTimeout);
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

  /// Whether a finished bootstrap run means motifd is ready.
  ///
  /// A zero exit code is the clean success path. dartssh2 also reports a *null*
  /// exit code on servers that close the channel without sending an exit-status
  /// message even after a clean `exit 0` — so a null code alone must NOT be
  /// treated as failure (the bug behind "failed before motifd became ready"
  /// despite stdout saying "motifd already running"). Accept null only when the
  /// script printed a definitive readiness marker, so a genuine crash (null
  /// exit, no marker) still fails. Any non-zero code is always a failure (the
  /// script exits 0 immediately after the marker).
  static bool bootstrapReady({required int? exitCode, required String stdout}) {
    if (exitCode == 0) return true;
    if (exitCode == null) return _stdoutShowsReady(stdout);
    return false;
  }

  static bool _stdoutShowsReady(String stdout) =>
      stdout.contains('motifd already running on') ||
      stdout.contains('motifd started on');

  /// Whether a failed remote bootstrap explicitly requested the local
  /// download + SSH upload fallback.
  static bool shouldUseLocalDownloadFallback({
    required String stdout,
    required String stderr,
  }) => _localUploadRequest(stdout: stdout, stderr: stderr) != null;

  static _LocalUploadRequest? _localUploadRequest({
    required String stdout,
    required String stderr,
  }) {
    final match = _remoteDownloadFailure.firstMatch('$stderr\n$stdout');
    if (match == null) return null;
    return _LocalUploadRequest(
      platform: match.group(1)!,
      arch: match.group(2)!,
      uploadPath: match.group(3)!.trim(),
    );
  }

  /// Selects and validates the stable archive matching the SSH target.
  static MotifdReleaseAsset? releaseAsset(
    Object? metadata, {
    required String platform,
    required String arch,
  }) {
    if (metadata is! Map ||
        metadata['schema'] != 1 ||
        metadata['channel'] != 'stable' ||
        metadata['product'] != 'motifd') {
      return null;
    }
    final assets = metadata['assets'];
    if (assets is! Map) return null;
    final asset = assets['$platform-$arch'];
    if (asset is! Map) return null;
    final suffix = '-$platform-$arch.tar.gz';
    final name = asset['file'];
    final downloadUrl = asset['url'];
    final checksum = asset['sha256'];
    final size = asset['size'];
    if (name is! String ||
        downloadUrl is! String ||
        checksum is! String ||
        size is! int ||
        size <= 0 ||
        !name.startsWith('motifd-') ||
        !name.endsWith(suffix) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
      return null;
    }
    final uri = Uri.tryParse(downloadUrl);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      return null;
    }
    return MotifdReleaseAsset(url: uri, sha256: checksum, size: size);
  }

  static Uri stableMetadataUrl(String repository) {
    final parts = repository.split('/');
    if (parts.length != 2 || parts.any((part) => part.trim().isEmpty)) {
      throw ArgumentError.value(repository, 'repository');
    }
    return Uri.https(
      '${parts[0]}.github.io',
      '/${parts[1]}/meta/v1/motifd/stable.json',
    );
  }

  static String buildScript({
    required String repository,
    required String remoteHost,
    required int remotePort,
    required String token,
    String metadataUrl = '',
    String uploadedArchive = '',
  }) {
    final qRepository = _shQuote(repository);
    final qHost = _shQuote(remoteHost);
    final qPort = _shQuote('$remotePort');
    final qToken = _shQuote(token);
    final resolvedMetadataUrl = metadataUrl.isEmpty
        ? stableMetadataUrl(repository).toString()
        : metadataUrl;
    final qMetadataUrl = _shQuote(resolvedMetadataUrl);
    final qUploadedArchive = _shQuote(uploadedArchive);
    return '''
set -eu

REPOSITORY=$qRepository
REMOTE_HOST=$qHost
REMOTE_PORT=$qPort
TOKEN_VALUE=$qToken
METADATA_URL=$qMetadataUrl
UPLOADED_ARCHIVE=$qUploadedArchive

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
  max_time="\$3"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --connect-timeout 15 --max-time "\$max_time" "\$url" -o "\$out"; then
      return 0
    else
      code=\$?
      echo "curl failed to download \$url (exit \$code)" >&2
      return "\$code"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO "\$out" -T "\$max_time" -t 1 "\$url"; then
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

verify_sha256() {
  file="\$1"
  expected="\$2"
  if command -v sha256sum >/dev/null 2>&1; then
    actual=\$(sha256sum "\$file" | sed 's/[[:space:]].*//')
  elif command -v shasum >/dev/null 2>&1; then
    actual=\$(shasum -a 256 "\$file" | sed 's/[[:space:]].*//')
  elif command -v openssl >/dev/null 2>&1; then
    actual=\$(openssl dgst -sha256 "\$file" | sed 's/^.*= //')
  else
    echo "sha256sum, shasum, or openssl is required to verify motifd" >&2
    return 127
  fi
  if [ "\$actual" != "\$expected" ]; then
    echo "motifd SHA-256 mismatch: expected \$expected, got \$actual" >&2
    return 1
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

can_ping_motifd() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
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

  upload_path="\$BIN_DIR/motifd-\$platform-\$arch-upload.tar.gz"
  remote_download_failed() {
    printf 'MOTIFD_REMOTE_DOWNLOAD_FAILED platform=%s arch=%s upload=%s\\n' "\$platform" "\$arch" "\$upload_path" >&2
  }

  tmp=\$(mktemp -d)
  trap 'rm -rf "\$tmp"' EXIT HUP INT TERM
  if [ -n "\$UPLOADED_ARCHIVE" ]; then
    if [ ! -f "\$UPLOADED_ARCHIVE" ]; then
      echo "SSH-uploaded motifd archive is missing: \$UPLOADED_ARCHIVE" >&2
      exit 28
    fi
    echo "installing motifd asset uploaded over SSH"
    cp "\$UPLOADED_ARCHIVE" "\$tmp/motifd.tar.gz"
  else
    echo "downloading stable motifd metadata from \$METADATA_URL"
    if ! download_to "\$METADATA_URL" "\$tmp/release.json" 30; then
      remote_download_failed
      exit 26
    fi
    asset_block=\$(
      sed -n "/\\"\$platform-\$arch\\"[[:space:]]*:/,/^[[:space:]]*}/p" "\$tmp/release.json"
    )
    asset_url=\$(
      printf '%s\\n' "\$asset_block" |
        sed -n 's|.*"url"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*|\\1|p'
    )
    asset_sha=\$(
      printf '%s\\n' "\$asset_block" |
        sed -n 's|.*"sha256"[[:space:]]*:[[:space:]]*"\\([0-9a-f]*\\)".*|\\1|p'
    )
    if [ -z "\$asset_url" ] || [ "\${#asset_sha}" -ne 64 ]; then
      echo "stable metadata has no valid motifd asset for \$platform-\$arch" >&2
      exit 22
    fi
    echo "downloading motifd asset from \$asset_url"
    if ! download_to "\$asset_url" "\$tmp/motifd.tar.gz" 180; then
      remote_download_failed
      exit 27
    fi
    if ! verify_sha256 "\$tmp/motifd.tar.gz" "\$asset_sha"; then
      remote_download_failed
      exit 29
    fi
  fi
  echo "extracting motifd archive"
  tar -xzf "\$tmp/motifd.tar.gz" -C "\$tmp"
  found=\$(find "\$tmp" -type f -name motifd -print | head -n 1)
  if [ -z "\$found" ]; then
    echo "downloaded motifd archive did not contain motifd" >&2
    exit 23
  fi
  cp "\$found" "\$BIN"
  chmod 0755 "\$BIN"
  if [ -n "\$UPLOADED_ARCHIVE" ]; then
    rm -f "\$UPLOADED_ARCHIVE"
  fi
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

if [ -f "\$PID_FILE" ]; then
  old_pid=\$(cat "\$PID_FILE" 2>/dev/null || true)
  if [ -n "\$old_pid" ] && kill -0 "\$old_pid" 2>/dev/null; then
    if ping_motifd || ! can_ping_motifd; then
      echo "motifd already running on \$LISTEN"
      exit 0
    fi
  fi
fi

# The caller reaches this listener through a trusted loopback path: either an
# SSH tunnel or Windows/WSL localhost forwarding. A network-facing listener
# would instead need motifd's encrypted pairing flow.
echo "starting motifd on \$LISTEN; log: \$LOG_FILE"
nohup "\$BIN" --listen "\$LISTEN" >>"\$LOG_FILE" 2>&1 </dev/null &
pid=\$!
printf '%s\\n' "\$pid" > "\$PID_FILE"

# A host without curl/wget reaches this path through the local-download
# fallback. In that case process liveness is the best check available here;
# the SSH tunnel performs the real HTTP readiness check immediately afterward.
if ! can_ping_motifd; then
  sleep 2
  if kill -0 "\$pid" 2>/dev/null; then
    echo "motifd started on \$LISTEN"
    exit 0
  fi
  echo "motifd exited during startup; log follows" >&2
  tail -n 80 "\$LOG_FILE" >&2 2>/dev/null || true
  exit 24
fi

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

  static const Map<String, String> _metadataHeaders = <String, String>{
    'Accept': 'application/json',
    'User-Agent': 'Motif-SSH-Bootstrap',
  };

  static const Map<String, String> _assetHeaders = <String, String>{
    'Accept': 'application/octet-stream',
    'User-Agent': 'Motif-SSH-Bootstrap',
  };

  static final RegExp _remoteDownloadFailure = RegExp(
    r'MOTIFD_REMOTE_DOWNLOAD_FAILED platform=(linux|macos) '
    r'arch=(x86_64|arm64) upload=([^\r\n]+)',
  );
}

class MotifdReleaseAsset {
  const MotifdReleaseAsset({
    required this.url,
    required this.sha256,
    required this.size,
  });

  final Uri url;
  final String sha256;
  final int size;
}

class _LocalUploadRequest {
  const _LocalUploadRequest({
    required this.platform,
    required this.arch,
    required this.uploadPath,
  });

  final String platform;
  final String arch;
  final String uploadPath;
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
