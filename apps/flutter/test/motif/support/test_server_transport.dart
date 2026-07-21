import 'dart:typed_data';

import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/state/server/server_transport.dart';

typedef TestServerConnect =
    Future<PingInfo> Function(
      TestServerTransport transport,
      MotifServer server, {
      required bool force,
      required ProxySettings proxy,
      required Uint8List? certPin,
    });

typedef TestServerCall =
    Future<Map<String, Object?>> Function(
      String method, [
      Map<String, Object?> params,
    ]);

/// Configurable server-scoped transport for tests. It intentionally has no
/// dependency on Workspace controllers or ViewModels.
final class TestServerTransport implements ServerTransport {
  TestServerTransport({
    bool live = false,
    this.onConnect,
    this.onCall,
    this.onClose,
    this.onWriteFileBytes,
  }) : isLive = live;

  @override
  bool isLive;

  @override
  PingInfo? lastPing;

  final TestServerConnect? onConnect;
  final TestServerCall? onCall;
  final Future<void> Function()? onClose;
  final Future<String> Function(String path, Uint8List data)? onWriteFileBytes;

  int connectCalls = 0;
  int closeCalls = 0;
  final List<bool> connectForces = [];

  void setLive(bool value) => isLive = value;

  @override
  Future<PingInfo> connect(
    MotifServer server, {
    required bool force,
    required ProxySettings proxy,
    required Uint8List? certPin,
  }) async {
    connectCalls++;
    connectForces.add(force);
    final ping =
        await onConnect?.call(
          this,
          server,
          force: force,
          proxy: proxy,
          certPin: certPin,
        ) ??
        const PingInfo(service: 'motif-server', version: 'test');
    isLive = true;
    lastPing = ping;
    return ping;
  }

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) => onCall?.call(method, params) ?? Future.value(const {});

  @override
  Future<String> writeFileBytes(String path, Uint8List data) =>
      onWriteFileBytes?.call(path, data) ?? Future.value('');

  @override
  Future<void> close() async {
    closeCalls++;
    await onClose?.call();
    isLive = false;
  }
}
