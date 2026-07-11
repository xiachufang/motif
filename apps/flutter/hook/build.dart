import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

// @Native resolves bundled assets by package URI, which omits the leading lib/.
// Motif is a remote terminal: the engine (libghostty-vt) renders bytes relayed
// from motifd's PTY, so no local PTY library is built or bundled.
const _ghosttyAssetName = 'motif/terminal/ghostty_bindings.g.dart';
const _tailscaleAssetName = 'motif/platform/tailscale_ffi.dart';
// The embedded-server cdylib (a C ABI over motif-server). Desktop only — the
// app runs an in-process motifd from the tray, like the Tauri menu-bar app.
const _motifEmbedAssetName = 'motif/platform/motif_embed_ffi.dart';
const _homebrewZig = '/opt/homebrew/opt/zig@0.15/bin/zig';

bool _envFlagEnabled(String name) {
  final value = Platform.environment[name]?.toLowerCase();
  return value == '1' || value == 'true' || value == 'yes';
}

/// Whether the Zig toolchain is discoverable on PATH.
Future<bool> _hasZig() async {
  for (final candidate in ['zig', _homebrewZig]) {
    try {
      final result = await Process.run(candidate, ['version']);
      if (result.exitCode == 0) return true;
    } catch (_) {
      // Try the next candidate.
    }
  }
  return false;
}

Future<bool> _hasCargo() async {
  try {
    final result = await Process.run('cargo', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Resolve a bash to run the build scripts with.
///
/// On Windows, a bare `bash` is a trap: Dart's Process.start uses CreateProcess,
/// whose search order hits C:\Windows\System32 before PATH — and System32\bash
/// is the WSL launcher, which errors out ("no installed distributions") when no
/// distro is present. So prefer an explicit Git Bash (overridable via
/// MOTIF_BASH); fall back to PATH `bash` on Unix.
String _bashExecutable() {
  final override = Platform.environment['MOTIF_BASH'];
  if (override != null && override.isNotEmpty) return override;
  if (Platform.isWindows) {
    for (final candidate in [
      r'C:\Program Files\Git\bin\bash.exe',
      r'C:\Program Files\Git\usr\bin\bash.exe',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return 'bash';
}

File? _findRelativeFile(BuildInput input, List<String> relativeCandidates) {
  for (final relativePath in relativeCandidates) {
    final lib = File.fromUri(input.packageRoot.resolve(relativePath));
    if (lib.existsSync()) return lib;
  }
  return null;
}

void _addBundledTailscaleDynamicFile(
  BuildInput input,
  BuildOutputBuilder output,
  File lib,
) {
  output.dependencies.add(lib.uri);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _tailscaleAssetName,
      file: lib.uri,
      linkMode: DynamicLoadingBundled(),
    ),
  );
}

Future<void> _addOrBuildBundledTailscaleDynamic(
  BuildInput input,
  BuildOutputBuilder output, {
  required List<String> relativeCandidates,
  String? buildTarget,
  Map<String, String>? environment,
}) async {
  var lib = _findRelativeFile(input, relativeCandidates);
  if (lib == null && buildTarget != null) {
    await _runTailscaleBuild(input, buildTarget, environment: environment);
    lib = _findRelativeFile(input, relativeCandidates);
  }
  if (lib == null) return;
  _addBundledTailscaleDynamicFile(input, output, lib);
}

Future<void> _runTailscaleBuild(
  BuildInput input,
  String target, {
  Map<String, String>? environment,
}) async {
  final packageRoot = Directory.fromUri(input.packageRoot).path;
  final buildScript = File.fromUri(
    input.packageRoot.resolve('scripts/build_tailscale.sh'),
  );
  if (!buildScript.existsSync()) {
    throw StateError('Missing build script: ${buildScript.path}');
  }
  final args = ['bash', buildScript.path, '--target', target];
  final process = await Process.start(
    '/usr/bin/env',
    args,
    workingDirectory: packageRoot,
    environment: environment,
  );
  await stdout.addStream(process.stdout);
  await stderr.addStream(process.stderr);
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw ProcessException(
      '/usr/bin/env',
      args,
      'Tailscale native build failed for $target',
      exitCode,
    );
  }
}

void _addBundledMotifEmbedDynamicFile(
  BuildInput input,
  BuildOutputBuilder output,
  File lib,
) {
  output.dependencies.add(lib.uri);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _motifEmbedAssetName,
      file: lib.uri,
      linkMode: DynamicLoadingBundled(),
    ),
  );
}

/// Build motif-embed via cargo and bundle it. Cargo handles freshness, so Rust
/// source changes update the bundled embedded server without deleting build/.
/// Set MOTIF_EMBED_USE_PREBUILT=1 to force the old prebuilt-only path.
Future<void> _addOrBuildBundledMotifEmbedDynamic(
  BuildInput input,
  BuildOutputBuilder output, {
  required List<String> relativeCandidates,
  String? buildTarget,
  Map<String, String>? environment,
}) async {
  final usePrebuilt = _envFlagEnabled('MOTIF_EMBED_USE_PREBUILT');
  var lib = usePrebuilt ? _findRelativeFile(input, relativeCandidates) : null;

  if (buildTarget != null && !usePrebuilt) {
    final canBuild = await _hasCargo();
    if (!canBuild) {
      lib = _findRelativeFile(input, relativeCandidates);
      if (lib == null) {
        throw StateError(
          'cargo is required to build motif-embed, or set '
          'MOTIF_EMBED_USE_PREBUILT=1 and provide a prebuilt library.',
        );
      }
    } else {
      await _runMotifEmbedBuild(input, buildTarget, environment: environment);
      lib = _findRelativeFile(input, relativeCandidates);
    }
  }

  lib ??= _findRelativeFile(input, relativeCandidates);
  if (lib == null && buildTarget != null && usePrebuilt) {
    throw StateError(
      'MOTIF_EMBED_USE_PREBUILT=1 was set, but no prebuilt motif-embed '
      'library was found.',
    );
  }
  if (lib == null) return;
  _addBundledMotifEmbedDynamicFile(input, output, lib);
}

Future<void> _runMotifEmbedBuild(
  BuildInput input,
  String target, {
  Map<String, String>? environment,
}) async {
  final packageRoot = Directory.fromUri(input.packageRoot).path;
  final buildScript = File.fromUri(
    input.packageRoot.resolve('scripts/build_motif_embed.sh'),
  );
  if (!buildScript.existsSync()) {
    throw StateError('Missing build script: ${buildScript.path}');
  }
  final args = ['bash', buildScript.path, '--target', target];
  final process = await Process.start(
    '/usr/bin/env',
    args,
    workingDirectory: packageRoot,
    environment: environment,
  );
  await stdout.addStream(process.stdout);
  await stderr.addStream(process.stderr);
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw ProcessException(
      '/usr/bin/env',
      args,
      'motif-embed native build failed for $target',
      exitCode,
    );
  }
}

/// Linux native build: cross-/native-compile libghostty-vt.so and emit it as a
/// bundled dynamic library.
Future<void> _buildLinux(BuildInput input, BuildOutputBuilder output) async {
  final codeConfig = input.config.code;
  final arch = switch (codeConfig.targetArchitecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x64',
    _ => throw UnsupportedError(
      'Unsupported Linux arch: ${codeConfig.targetArchitecture.name}',
    ),
  };

  final packageRoot = Directory.fromUri(input.packageRoot).path;
  final buildScript = File.fromUri(
    input.packageRoot.resolve('scripts/build_native_deps.sh'),
  );
  if (!buildScript.existsSync()) {
    throw StateError('Missing build script: ${buildScript.path}');
  }
  final outDir = Directory.fromUri(
    input.outputDirectory.resolve('native/linux/'),
  );
  outDir.createSync(recursive: true);

  final args = [
    'bash',
    buildScript.path,
    '--target-os',
    'linux',
    '--target-arch',
    arch,
    '--out-dir',
    outDir.path,
  ];
  final process = await Process.start(
    '/usr/bin/env',
    args,
    workingDirectory: packageRoot,
  );
  await stdout.addStream(process.stdout);
  await stderr.addStream(process.stderr);
  if (await process.exitCode != 0) {
    throw ProcessException('/usr/bin/env', args, 'Linux native build failed');
  }

  final ghosttyLib = File.fromUri(outDir.uri.resolve('libghostty-vt.so'));
  if (!ghosttyLib.existsSync()) {
    throw StateError('Expected Linux .so lib missing under ${outDir.path}');
  }

  output.dependencies.add(buildScript.uri);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _ghosttyAssetName,
      file: ghosttyLib.uri,
      linkMode: DynamicLoadingBundled(),
    ),
  );
  await _addOrBuildBundledTailscaleDynamic(
    input,
    output,
    relativeCandidates: [
      'build/native/tailscale/linux/$arch/libtailscale.so',
      'build/native/tailscale/libtailscale.so',
      'linux/vendor/libtailscale.so',
    ],
    buildTarget: 'linux-$arch',
  );
  await _addOrBuildBundledMotifEmbedDynamic(
    input,
    output,
    relativeCandidates: [
      'build/native/motif/linux/$arch/libmotif_embed.so',
      'linux/vendor/libmotif_embed.so',
    ],
    buildTarget: 'linux-$arch',
  );
}

/// Android native build: libghostty-vt.so (per ABI).
/// Requires the Android NDK (ANDROID_NDK_HOME / ANDROID_HOME).
Future<void> _buildAndroid(BuildInput input, BuildOutputBuilder output) async {
  final codeConfig = input.config.code;
  final arch = switch (codeConfig.targetArchitecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x64',
    Architecture.arm => 'arm',
    _ => throw UnsupportedError(
      'Unsupported Android arch: ${codeConfig.targetArchitecture.name}',
    ),
  };

  final packageRoot = Directory.fromUri(input.packageRoot).path;
  final buildScript = File.fromUri(
    input.packageRoot.resolve('scripts/build_native_deps.sh'),
  );
  if (!buildScript.existsSync()) {
    throw StateError('Missing build script: ${buildScript.path}');
  }
  final outDir = Directory.fromUri(
    input.outputDirectory.resolve('native/android/$arch/'),
  );
  outDir.createSync(recursive: true);

  final args = [
    'bash',
    buildScript.path,
    '--target-os',
    'android',
    '--target-arch',
    arch,
    '--out-dir',
    outDir.path,
  ];
  final process = await Process.start(
    '/usr/bin/env',
    args,
    workingDirectory: packageRoot,
  );
  await stdout.addStream(process.stdout);
  await stderr.addStream(process.stderr);
  if (await process.exitCode != 0) {
    throw ProcessException('/usr/bin/env', args, 'Android native build failed');
  }

  final ghosttyLib = File.fromUri(outDir.uri.resolve('libghostty-vt.so'));
  if (!ghosttyLib.existsSync()) {
    throw StateError('Expected Android .so lib missing under ${outDir.path}');
  }

  output.dependencies.add(buildScript.uri);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _ghosttyAssetName,
      file: ghosttyLib.uri,
      linkMode: DynamicLoadingBundled(),
    ),
  );
  final abi = switch (arch) {
    'arm64' => 'arm64-v8a',
    'x64' => 'x86_64',
    'arm' => 'armeabi-v7a',
    _ => arch,
  };
  await _addOrBuildBundledTailscaleDynamic(
    input,
    output,
    relativeCandidates: [
      'build/native/tailscale/android/$arch/libtailscale.so',
      'android/app/src/main/jniLibs/$abi/libtailscale.so',
    ],
    buildTarget: 'android-$arch',
  );
}

/// Windows native build: libghostty-vt.dll (ghostty-vt.dll).
Future<void> _buildWindows(BuildInput input, BuildOutputBuilder output) async {
  final codeConfig = input.config.code;
  final arch = switch (codeConfig.targetArchitecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x64',
    _ => throw UnsupportedError(
      'Unsupported Windows arch: ${codeConfig.targetArchitecture.name}',
    ),
  };

  final packageRoot = Directory.fromUri(input.packageRoot).path;
  final buildScript = File.fromUri(
    input.packageRoot.resolve('scripts/build_native_deps.sh'),
  );
  if (!buildScript.existsSync()) {
    throw StateError('Missing build script: ${buildScript.path}');
  }
  final outDir = Directory.fromUri(
    input.outputDirectory.resolve('native/windows/'),
  );
  outDir.createSync(recursive: true);

  // Invoke bash directly, not via `/usr/bin/env`: this hook runs in the native
  // Windows flutter/dart process (not inside Git Bash), where the Unix path
  // `/usr/bin/env` does not exist. `bash` resolves on PATH (Git Bash's bash).
  //
  // Dart hands us native Windows paths with backslashes (D:\a\...). bash treats
  // `\` as an escape, so the script's `dirname`/`cd`/`mkdir` on these paths
  // break (it fails within seconds). Convert to forward slashes — msys bash
  // accepts `D:/a/...` as the script path and --out-dir.
  final bash = _bashExecutable();
  final args = [
    buildScript.path.replaceAll(r'\', '/'),
    '--target-os',
    'windows',
    '--target-arch',
    arch,
    '--out-dir',
    outDir.path.replaceAll(r'\', '/'),
  ];
  final process = await Process.start(
    bash,
    args,
    workingDirectory: packageRoot,
  );
  await stdout.addStream(process.stdout);
  await stderr.addStream(process.stderr);
  if (await process.exitCode != 0) {
    throw ProcessException(bash, args, 'Windows native build failed');
  }

  final ghosttyLib = File.fromUri(outDir.uri.resolve('ghostty-vt.dll'));
  if (!ghosttyLib.existsSync()) {
    throw StateError('Expected Windows .dll lib missing under ${outDir.path}');
  }

  output.dependencies.add(buildScript.uri);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _ghosttyAssetName,
      file: ghosttyLib.uri,
      linkMode: DynamicLoadingBundled(),
    ),
  );
  // Windows bundles only the terminal engine (ghostty-vt) — no libtailscale
  // and no embedded motifd:
  //   - libtailscale: upstream's C wrapper (tailscale.c) is POSIX-only
  //     (<sys/socket.h>, <unistd.h>) with no winsock fallback.
  //   - motif-embed (in-process motifd): motif-server is Unix-centric (a
  //     Unix-domain hook-ingress socket, fs-permission calls), so it isn't
  //     built for Windows.
  // The app degrades gracefully when these are absent: _findLibtailscale()
  // returns null → NoopTailscaleService, and EmbeddedServerService.available
  // is false → the embedded-server UI hides. The Windows client is a pure
  // remote client (connects to a remote motifd).
}

/// iOS native build: wrap libghostty-vt's iOS archive slice into a bundled
/// dylib and emit it as a dynamic native asset.
Future<void> _buildIOS(BuildInput input, BuildOutputBuilder output) async {
  final codeConfig = input.config.code;
  final iosSdk = codeConfig.iOS.targetSdk == IOSSdk.iPhoneSimulator
      ? 'iphonesimulator'
      : 'iphoneos';
  // The Flutter tool reports its own iOS floor (13) here, but the zig-built
  // ghostty-vt archive slices target iOS 17 (ghostty's minimum), as does the
  // Runner app. Floor the dylib link at 17 to avoid ld's "object file was
  // built for newer 'iOS' version" warning.
  const ghosttyIOSMin = 17;
  final minVersion = codeConfig.iOS.targetVersion < ghosttyIOSMin
      ? ghosttyIOSMin
      : codeConfig.iOS.targetVersion;
  final arch = switch (codeConfig.targetArchitecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x64',
    _ => throw UnsupportedError(
      'Unsupported iOS arch: ${codeConfig.targetArchitecture.name}',
    ),
  };

  final packageRoot = Directory.fromUri(input.packageRoot).path;
  final buildScript = File.fromUri(
    input.packageRoot.resolve('scripts/build_native_deps.sh'),
  );
  if (!buildScript.existsSync()) {
    throw StateError('Missing build script: ${buildScript.path}');
  }
  final outDir = Directory.fromUri(
    input.outputDirectory.resolve('native/ios/'),
  );
  outDir.createSync(recursive: true);

  final args = [
    'bash',
    buildScript.path,
    '--target-os',
    'ios',
    '--target-arch',
    arch,
    '--ios-sdk',
    iosSdk,
    '--ios-min-version',
    '$minVersion',
    '--out-dir',
    outDir.path,
  ];
  final process = await Process.start(
    '/usr/bin/env',
    args,
    workingDirectory: packageRoot,
  );
  await stdout.addStream(process.stdout);
  await stderr.addStream(process.stderr);
  if (await process.exitCode != 0) {
    throw ProcessException('/usr/bin/env', args, 'iOS native build failed');
  }

  final ghosttyLib = File.fromUri(outDir.uri.resolve('libghostty-vt.dylib'));
  if (!ghosttyLib.existsSync()) {
    throw StateError('Expected iOS dylib missing under ${outDir.path}');
  }

  output.dependencies.add(buildScript.uri);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _ghosttyAssetName,
      file: ghosttyLib.uri,
      linkMode: DynamicLoadingBundled(),
    ),
  );

  final tailscaleBuildTarget = switch ((iosSdk, arch)) {
    ('iphoneos', 'arm64') => 'ios',
    ('iphonesimulator', 'arm64') => 'ios-sim-arm64',
    ('iphonesimulator', 'x64') => 'ios-sim-x64',
    _ => null,
  };
  if (tailscaleBuildTarget == null) return;
  await _addOrBuildBundledTailscaleDynamic(
    input,
    output,
    relativeCandidates: [
      'build/native/tailscale/$iosSdk/$arch/libtailscale.dylib',
      'build/native/tailscale/$iosSdk/libtailscale.dylib',
      'ios/vendor/libtailscale.dylib',
    ],
    buildTarget: tailscaleBuildTarget,
    environment: {'IOS_MIN_VERSION': '$minVersion'},
  );
}

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    // Pure Dart/widget CI does not execute FFI-backed terminal tests. Avoid
    // compiling Ghostty, Tailscale and motif-embed for that test lane.
    if (_envFlagEnabled('MOTIF_SKIP_NATIVE_ASSETS')) {
      return;
    }

    final codeConfig = input.config.code;
    final targetOS = codeConfig.targetOS;

    if (!await _hasZig()) {
      throw StateError(
        'Zig 0.15 is required to build libghostty-vt. Expected `zig` on PATH '
        'or at $_homebrewZig.',
      );
    }

    if (targetOS == OS.iOS) {
      await _buildIOS(input, output);
      return;
    }
    if (targetOS == OS.linux) {
      await _buildLinux(input, output);
      return;
    }
    if (targetOS == OS.windows) {
      await _buildWindows(input, output);
      return;
    }
    if (targetOS == OS.android) {
      await _buildAndroid(input, output);
      return;
    }
    if (targetOS != OS.macOS) {
      return;
    }

    final targetArch = codeConfig.targetArchitecture;
    final targetArchName = switch (targetArch) {
      Architecture.arm64 => 'arm64',
      Architecture.x64 => 'x64',
      _ => throw UnsupportedError(
        'Unsupported macOS architecture for native deps: ${targetArch.name}',
      ),
    };

    final packageRoot = Directory.fromUri(input.packageRoot).path;
    final buildScript = File.fromUri(
      input.packageRoot.resolve('scripts/build_native_deps.sh'),
    );
    if (!buildScript.existsSync()) {
      throw StateError('Missing build script: ${buildScript.path}');
    }

    final outDir = Directory.fromUri(
      input.outputDirectory.resolve('native/$targetArchName/'),
    );
    outDir.createSync(recursive: true);

    final macOSMinVersion = codeConfig.macOS.targetVersion;
    final processArgs = [
      'bash',
      buildScript.path,
      '--target-os',
      'macos',
      '--target-arch',
      targetArchName,
      '--out-dir',
      outDir.path,
      '--macos-min-version',
      '$macOSMinVersion',
    ];
    final process = await Process.start(
      '/usr/bin/env',
      processArgs,
      workingDirectory: packageRoot,
    );

    await stdout.addStream(process.stdout);
    await stderr.addStream(process.stderr);
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw ProcessException(
        '/usr/bin/env',
        processArgs,
        'Native build failed for macOS/$targetArchName',
        exitCode,
      );
    }

    final ghosttyLib = File.fromUri(outDir.uri.resolve('libghostty-vt.dylib'));
    if (!ghosttyLib.existsSync()) {
      throw StateError('Expected output missing: ${ghosttyLib.path}');
    }

    output.dependencies.add(buildScript.uri);

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _ghosttyAssetName,
        file: ghosttyLib.uri,
        linkMode: DynamicLoadingBundled(),
      ),
    );
    await _addOrBuildBundledTailscaleDynamic(
      input,
      output,
      relativeCandidates: [
        'build/native/tailscale/macos/$targetArchName/libtailscale.dylib',
        'build/native/tailscale/libtailscale.dylib',
        'macos/vendor/libtailscale.dylib',
      ],
      buildTarget: 'macos-$targetArchName',
      environment: {'MACOSX_DEPLOYMENT_TARGET': '$macOSMinVersion'},
    );
    await _addOrBuildBundledMotifEmbedDynamic(
      input,
      output,
      relativeCandidates: [
        'build/native/motif/macos/$targetArchName/libmotif_embed.dylib',
        'macos/vendor/libmotif_embed.dylib',
      ],
      buildTarget: 'macos-$targetArchName',
      environment: {'MACOSX_DEPLOYMENT_TARGET': '$macOSMinVersion'},
    );
  });
}
