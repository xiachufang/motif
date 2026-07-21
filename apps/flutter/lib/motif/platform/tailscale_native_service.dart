/// A real [TailscaleService] backed by `libtailscale` (tsnet) over FFI.
///
/// Brings up a tsnet node and starts the loopback SOCKS5/HTTP proxy; the proxy
/// address + credential are exposed so the RPC transport can route through the
/// tailnet (see `net/tailscale_proxy.dart`). Headless auth uses an auth key;
/// interactive auth starts the tsnet LocalAPI and surfaces the web sign-in URL.
///
/// `tailscale_up` blocks until the node is usable, so it runs on a worker
/// isolate — the Go runtime + handle are process-global, so the same `int`
/// handle is valid across isolates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../log/log.dart';
import '../models/motif_proto.dart';
import '../net/proxy_client.dart';
import 'services.dart';
import 'tailscale_ffi.dart';

class TailscaleNativeService extends TailscaleService {
  static const _logName = 'motif.tailscale';
  static const _healthProbeInterval = Duration(seconds: 5);
  static const _healthProbeTimeout = Duration(seconds: 2);
  static const _maxMissedHealthProbes = 2;
  static const _maxConsecutiveDegradedProbes = 4;
  static const _autoRestartMinInterval = Duration(minutes: 2);

  final String dylibPath;
  final String stateDir;
  final String hostname;
  final String? controlUrl;

  TailscaleNativeService({
    required this.dylibPath,
    required this.stateDir,
    this.hostname = 'motif-flutter',
    this.controlUrl,
  });

  LibTailscale? _lib;
  int? _sd;
  TailscaleLoopback? _loopback;
  int _generation = 0;
  Timer? _healthTimer;
  bool _healthProbeInFlight = false;
  int _missedHealthProbes = 0;
  int _consecutiveDegradedProbes = 0;
  String? _lastBackendState;
  String? _lastAuthKey;
  DateTime? _lastAutoRestartAt;
  bool _restarting = false;

  /// The active loopback proxy (host:port + credential), or null when not up.
  TailscaleLoopback? get proxy => _loopback;

  LibTailscale _openLib() => LibTailscale.open(dylibPath);

  @override
  ProxySettings? get loopbackProxy {
    if (state.status != TailscaleStatus.running &&
        state.status != TailscaleStatus.degraded) {
      return null;
    }
    final lb = _loopback;
    if (lb == null) return null;
    final parts = lb.proxyAddr.split(':');
    if (parts.length != 2) return null;
    return ProxySettings(
      proxyHost: parts[0],
      proxyPort: int.tryParse(parts[1]),
      username: 'tsnet', // tsnet loopback SOCKS5 requires user "tsnet"...
      password: lb.proxyCred, // ...with the loopback credential as the password
    );
  }

  void _set(TailscaleState s) {
    if (state == s) return;
    Log.i(
      'state ${state.status.name} -> ${s.status.name}'
      '${s.detail == null ? '' : ' (${s.detail})'}',
      name: _logName,
    );
    tailscaleState = s;
  }

  bool _isCurrent(int generation, int sd) =>
      _generation == generation && _sd == sd;

  void _setCurrent(int generation, int sd, TailscaleState s) {
    if (_isCurrent(generation, sd)) _set(s);
  }

  @override
  Future<void> start({String? authKey}) async {
    final hasAuthKey = authKey != null && authKey.isNotEmpty;
    if (hasAuthKey) _lastAuthKey = authKey;
    final active =
        state.status == TailscaleStatus.running ||
        state.status == TailscaleStatus.starting ||
        (state.status == TailscaleStatus.needsAuth && _sd != null);
    if (active && hasAuthKey && state.status == TailscaleStatus.needsAuth) {
      await stop();
    } else if (active) {
      Log.i('start skipped; already ${state.status.name}', name: _logName);
      return;
    } else if (_sd != null) {
      // A leftover node from a degraded/failed session shares the state dir
      // with the one we are about to create; close it first.
      Log.i(
        'closing stale node before restart (was ${state.status.name})',
        name: _logName,
      );
      await stop();
    }
    Log.i('start hasAuthKey=$hasAuthKey stateDir=$stateDir', name: _logName);
    _set(const TailscaleState(TailscaleStatus.starting));
    final generation = ++_generation;
    try {
      final lib = _openLib();
      final sd = lib.create();
      if (sd < 0) {
        Log.e('tailscale_new failed sd=$sd', name: _logName);
        _set(
          const TailscaleState(
            TailscaleStatus.failed,
            detail: 'tailscale_new failed',
          ),
        );
        return;
      }
      Directory(stateDir).createSync(recursive: true);
      lib.setDir(sd, stateDir);
      lib.setHostname(sd, hostname);
      if (controlUrl != null) lib.setControlUrl(sd, controlUrl!);
      if (hasAuthKey) lib.setAuthkey(sd, authKey);
      _lib = lib;
      _sd = sd;

      if (hasAuthKey) {
        await _startWithAuthKey(lib, sd, generation);
      } else {
        await _startWithBrowserAuth(lib, sd, generation);
      }
    } catch (e, st) {
      Log.e('start failed', name: _logName, error: e, stackTrace: st);
      if (_generation == generation) {
        _set(TailscaleState(TailscaleStatus.failed, detail: '$e'));
      }
    }
  }

  Future<void> _startWithAuthKey(
    LibTailscale lib,
    int sd,
    int generation,
  ) async {
    final rc = await _runUp(sd);
    if (!_isCurrent(generation, sd)) return;
    if (!_handleUpResult(lib, sd, generation, rc)) return;
    await _ensureLoopback(lib, sd, generation);
  }

  Future<void> _startWithBrowserAuth(
    LibTailscale lib,
    int sd,
    int generation,
  ) async {
    final lb = lib.loopback(sd);
    if (lb == null) {
      Log.e(
        'loopback proxy failed: ${_detail(lib, sd, 'loopback proxy failed')}',
        name: _logName,
      );
      _setCurrent(
        generation,
        sd,
        TailscaleState(
          TailscaleStatus.degraded,
          detail: _detail(lib, sd, 'loopback proxy failed'),
        ),
      );
      return;
    }
    Log.i('loopback proxy at ${lb.proxyAddr}', name: _logName);
    _loopback = lb;
    final api = TailscaleLocalApiClient(loopback: lb);
    final upFuture = _runUp(
      sd,
    ).then<Object?>((rc) => rc, onError: (Object error) => error);
    String? authUrl;
    String? lastBackend;
    try {
      while (_isCurrent(generation, sd)) {
        final local = await api.status().timeout(
          const Duration(seconds: 2),
          onTimeout: () => null,
        );
        if (local != null) {
          if (local.backendState != lastBackend) {
            lastBackend = local.backendState;
            Log.i(
              'login backendState=$lastBackend hasAuthUrl=${local.authUrl != null}',
              name: _logName,
            );
          }
          authUrl = local.authUrl ?? authUrl;
          _setCurrent(generation, sd, local.toState(fallbackAuthUrl: authUrl));
        } else if (authUrl == null) {
          _setCurrent(
            generation,
            sd,
            const TailscaleState(
              TailscaleStatus.starting,
              detail: 'Waiting for Tailscale login URL…',
            ),
          );
        }

        final upResult = await Future.any<Object?>([
          upFuture,
          Future<Object?>.delayed(const Duration(seconds: 2), () => null),
        ]);
        if (upResult == null) continue;
        if (!_isCurrent(generation, sd)) return;
        if (upResult is! int) throw upResult;
        final rc = upResult;
        if (!_handleUpResult(lib, sd, generation, rc)) return;
        _setCurrent(
          generation,
          sd,
          const TailscaleState(TailscaleStatus.running),
        );
        _startHealthMonitor(generation, sd, lb);
        return;
      }
    } finally {
      api.close();
    }
  }

  Future<int> _runUp(int sd) {
    final path = dylibPath;
    return Isolate.run(() {
      // Re-open in the worker isolate; the Go runtime/handle is process-global.
      final l = LibTailscale.open(path);
      return l.up(sd);
    });
  }

  bool _handleUpResult(LibTailscale lib, int sd, int generation, int rc) {
    if (rc == 0) {
      Log.i('tailscale_up ok', name: _logName);
      return true;
    }
    final detail = _detail(lib, sd, 'tailscale_up rc=$rc');
    Log.e('tailscale_up failed rc=$rc detail=$detail', name: _logName);
    _setCurrent(
      generation,
      sd,
      TailscaleState(TailscaleStatus.failed, detail: detail),
    );
    return false;
  }

  Future<void> _ensureLoopback(LibTailscale lib, int sd, int generation) async {
    final lb = lib.loopback(sd);
    if (!_isCurrent(generation, sd)) return;
    if (lb == null) {
      Log.e(
        'loopback proxy failed: ${_detail(lib, sd, 'loopback proxy failed')}',
        name: _logName,
      );
      _setCurrent(
        generation,
        sd,
        TailscaleState(
          TailscaleStatus.degraded,
          detail: _detail(lib, sd, 'loopback proxy failed'),
        ),
      );
      return;
    }
    Log.i('loopback proxy at ${lb.proxyAddr}', name: _logName);
    _loopback = lb;
    _setCurrent(generation, sd, const TailscaleState(TailscaleStatus.running));
    _startHealthMonitor(generation, sd, lb);
  }

  void _startHealthMonitor(int generation, int sd, TailscaleLoopback loopback) {
    _healthTimer?.cancel();
    _missedHealthProbes = 0;
    _consecutiveDegradedProbes = 0;
    _lastBackendState = null;
    _healthProbeInFlight = false;
    _healthTimer = Timer.periodic(_healthProbeInterval, (_) {
      unawaited(_probeHealth(generation, sd, loopback));
    });
    unawaited(_probeHealth(generation, sd, loopback));
  }

  void _stopHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _healthProbeInFlight = false;
    _missedHealthProbes = 0;
    _consecutiveDegradedProbes = 0;
    _lastBackendState = null;
  }

  Future<void> _probeHealth(
    int generation,
    int sd,
    TailscaleLoopback loopback,
  ) async {
    if (_healthProbeInFlight || !_isCurrent(generation, sd)) return;
    _healthProbeInFlight = true;
    final api = TailscaleLocalApiClient(loopback: loopback);
    try {
      final local = await api.status().timeout(
        _healthProbeTimeout,
        onTimeout: () => null,
      );
      if (!_isCurrent(generation, sd)) return;
      if (local == null) {
        _missedHealthProbes++;
        Log.w('health probe missed ($_missedHealthProbes)', name: _logName);
        if (_missedHealthProbes >= _maxMissedHealthProbes) {
          _setCurrent(
            generation,
            sd,
            const TailscaleState(
              TailscaleStatus.degraded,
              detail: 'Tailscale status probe failed.',
            ),
          );
          _noteDegradedProbe(generation, sd);
        }
        return;
      }
      _missedHealthProbes = 0;
      if (local.backendState != _lastBackendState) {
        _lastBackendState = local.backendState;
        Log.i('health backendState=${local.backendState}', name: _logName);
      }
      final health = local.toHealthState();
      _setCurrent(generation, sd, health);
      if (health.status == TailscaleStatus.degraded) {
        _noteDegradedProbe(generation, sd);
      } else {
        _consecutiveDegradedProbes = 0;
      }
    } finally {
      api.close();
      _healthProbeInFlight = false;
    }
  }

  /// A reconnect that never converges (e.g. tsnet stuck in `Starting` after
  /// iOS suspended the app's sockets) shows up as a run of degraded probes.
  /// After [_maxConsecutiveDegradedProbes] in a row, tear the node down and
  /// bring up a fresh one — cached credentials in the state dir keep this
  /// headless. Rate-limited by [_autoRestartMinInterval].
  void _noteDegradedProbe(int generation, int sd) {
    _consecutiveDegradedProbes++;
    if (_consecutiveDegradedProbes < _maxConsecutiveDegradedProbes) return;
    if (!_isCurrent(generation, sd)) return;
    final now = DateTime.now();
    final last = _lastAutoRestartAt;
    if (last != null && now.difference(last) < _autoRestartMinInterval) return;
    _lastAutoRestartAt = now;
    _consecutiveDegradedProbes = 0;
    Log.w(
      'degraded for $_maxConsecutiveDegradedProbes consecutive probes; '
      'restarting tsnet node',
      name: _logName,
    );
    unawaited(_restart());
  }

  Future<void> _restart() async {
    if (_restarting) return;
    _restarting = true;
    try {
      await stop();
      await start(authKey: _lastAuthKey);
    } catch (e, st) {
      Log.e('tsnet restart failed', name: _logName, error: e, stackTrace: st);
    } finally {
      _restarting = false;
    }
  }

  String _detail(LibTailscale lib, int sd, String fallback) {
    final msg = lib.errmsg(sd).trim();
    return msg.isEmpty ? fallback : msg;
  }

  @override
  Future<void> stop() async {
    Log.i('stop (was ${state.status.name})', name: _logName);
    _generation++;
    _stopHealthMonitor();
    final lib = _lib, sd = _sd;
    if (lib != null && sd != null) {
      try {
        lib.close(sd);
      } catch (_) {}
    }
    _lib = null;
    _sd = null;
    _loopback = null;
    _set(TailscaleState.stopped);
  }

  @override
  Future<String> resolveHost(String host) async {
    if (_looksLikeIP(host)) return host;
    final normalized = _trimTrailingDot(host).toLowerCase();
    final peers = await discoverPeers();
    for (final peer in peers) {
      final dns = _trimTrailingDot(peer.dnsName).toLowerCase();
      final shortName = peer.hostname.toLowerCase();
      if (dns == normalized ||
          dns.startsWith('$normalized.') ||
          shortName == normalized) {
        return peer.primaryIP ?? peer.preferredAddress;
      }
    }
    return host;
  }

  @override
  Future<List<TailscalePeer>> discoverPeers() async {
    final lb = _loopback;
    if (lb == null || state.status != TailscaleStatus.running) return const [];
    final api = TailscaleLocalApiClient(loopback: lb);
    try {
      final status = await api.status(peers: true);
      final peers = status?.peers ?? const <TailscalePeer>[];
      return [...peers]..sort(compareDiscoveredPeers);
    } finally {
      api.close();
    }
  }

  @override
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (state.status != TailscaleStatus.running) {
      return const TailscalePingResult.unreachable('Tailscale off');
    }
    final proxy = loopbackProxy;
    if (proxy == null || !proxy.isActive) {
      return const TailscalePingResult.unreachable('Tailscale off');
    }

    final resolvedHost = await resolveHost(host);
    final client = makeHttpClient(proxy);
    try {
      final uri = Uri(
        scheme: 'http',
        host: resolvedHost,
        port: port,
        path: '/ping',
      );
      final response = await client.get(uri).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return TailscalePingResult.unreachable('HTTP ${response.statusCode}');
      }
      final json = jsonDecode(response.body);
      if (json is! Map) {
        return const TailscalePingResult.unreachable('Not motifd');
      }
      final info = PingInfo.fromJson(json.cast<String, Object?>());
      if (!info.isMotifServer) {
        return const TailscalePingResult.unreachable('Not motifd');
      }
      return TailscalePingResult.reachable(info.version);
    } on TimeoutException {
      return const TailscalePingResult.unreachable('No response');
    } on SocketException catch (e) {
      return TailscalePingResult.unreachable(_socketFailureMessage(e));
    } catch (_) {
      return const TailscalePingResult.unreachable('Ping failed');
    } finally {
      client.close();
    }
  }

  static bool _looksLikeIP(String host) {
    if (host.contains(':')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every(
      (part) => int.tryParse(part)?.clamp(0, 255).toString() == part,
    );
  }

  static String _trimTrailingDot(String value) =>
      value.endsWith('.') ? value.substring(0, value.length - 1) : value;

  static int compareDiscoveredPeers(TailscalePeer a, TailscalePeer b) {
    if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
    if (a.isLikelyMotifd != b.isLikelyMotifd) {
      return a.isLikelyMotifd ? -1 : 1;
    }
    return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
  }

  static String _socketFailureMessage(SocketException e) {
    final message = e.message.toLowerCase();
    if (message.contains('failed host lookup')) return 'Host not found';
    if (message.contains('connection refused')) return 'Port closed';
    return 'Ping failed';
  }
}

class TailscaleLocalApiClient {
  final TailscaleLoopback loopback;
  final http.Client _http;

  TailscaleLocalApiClient({required this.loopback, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  Future<TailscaleLocalStatus?> status({bool peers = false}) async {
    try {
      final response = await _http.get(
        Uri.parse(
          'http://${loopback.proxyAddr}/localapi/v0/status',
        ).replace(queryParameters: peers ? null : const {'peers': 'false'}),
        headers: {
          'Authorization':
              'Basic ${base64Encode(utf8.encode(':${loopback.localApiCred}'))}',
          'Sec-Tailscale': 'localapi',
        },
      );
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      if (json is! Map) return null;
      return TailscaleLocalStatus.fromJson(json.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  void close() => _http.close();
}

class TailscaleLocalStatus {
  final String? backendState;
  final String? authUrl;
  final List<TailscalePeer> peers;

  const TailscaleLocalStatus({
    this.backendState,
    this.authUrl,
    this.peers = const [],
  });

  factory TailscaleLocalStatus.fromJson(Map<String, Object?> json) {
    final authUrl = json['AuthURL'] as String?;
    final peers = <TailscalePeer>[
      if (json['Self'] is Map)
        _peerFromJson((json['Self'] as Map).cast<String, Object?>()),
      if (json['SelfStatus'] is Map)
        _peerFromJson((json['SelfStatus'] as Map).cast<String, Object?>()),
      if (json['Peer'] is Map)
        for (final value in (json['Peer'] as Map).values)
          if (value is Map) _peerFromJson(value.cast<String, Object?>()),
    ];
    return TailscaleLocalStatus(
      backendState: json['BackendState'] as String?,
      authUrl: authUrl == null || authUrl.isEmpty ? null : authUrl,
      peers: peers,
    );
  }

  TailscaleState toState({String? fallbackAuthUrl}) {
    final url = authUrl ?? fallbackAuthUrl;
    return switch (backendState) {
      'Running' => const TailscaleState(
        TailscaleStatus.starting,
        detail: 'Finalizing Tailscale session…',
      ),
      'NeedsLogin' => TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: url,
        detail: url == null
            ? 'Waiting for Tailscale login URL…'
            : 'Open the Tailscale login URL to continue.',
      ),
      'NeedsMachineAuth' => TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: url,
        detail: 'Waiting for tailnet admin approval.',
      ),
      'Stopped' => const TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale stopped while signing in.',
      ),
      'Starting' || 'NoState' || null => const TailscaleState(
        TailscaleStatus.starting,
        detail: 'Waiting for Tailscale login URL…',
      ),
      _ => TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale state: $backendState',
      ),
    };
  }

  TailscaleState toHealthState() {
    return switch (backendState) {
      'Running' => const TailscaleState(TailscaleStatus.running),
      'NeedsLogin' => TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: authUrl,
        detail: authUrl == null
            ? 'Tailscale login is required.'
            : 'Open the Tailscale login URL to continue.',
      ),
      'NeedsMachineAuth' => TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: authUrl,
        detail: 'Waiting for tailnet admin approval.',
      ),
      'Stopped' => const TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale disconnected.',
      ),
      'Starting' || 'NoState' || null => const TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale reconnecting…',
      ),
      _ => TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale state: $backendState',
      ),
    };
  }

  static TailscalePeer _peerFromJson(Map<String, Object?> json) {
    final hostname = (json['HostName'] as String?) ?? '';
    final dnsName = (json['DNSName'] as String?) ?? '';
    final ips = ((json['TailscaleIPs'] as List?) ?? const [])
        .whereType<String>()
        .toList();
    final primaryIP = ips.firstWhere(
      (ip) => ip.contains('.'),
      orElse: () => ips.isEmpty ? '' : ips.first,
    );
    final lower = hostname.toLowerCase();
    return TailscalePeer(
      hostname: hostname,
      dnsName: dnsName,
      primaryIP: primaryIP.isEmpty ? null : primaryIP,
      isLikelyMotifd: lower == 'motifd' || lower.startsWith('motifd-'),
      isOnline: (json['Online'] as bool?) ?? false,
    );
  }
}
