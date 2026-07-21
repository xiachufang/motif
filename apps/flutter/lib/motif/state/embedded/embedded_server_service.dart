/// Public embedded-server surface used by the shared app. The default
/// implementation is a pure-Dart no-op so web/mobile builds do not compile the
/// desktop-only motif-embed FFI library at all. Desktop entrypoints can inject a
/// real implementation with [EmbeddedServerFactory].
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../platform/secret_store.dart';
import 'embedded_server_models.dart';
import 'embedded_server_runtime_state.dart';
import 'embedded_server_view_model.dart';

export 'embedded_server_models.dart';

typedef EmbeddedServerFactory =
    Future<EmbeddedServerService> Function(
      SharedPreferences prefs,
      SecretStore secrets,
    );

Future<EmbeddedServerService> createNoopEmbeddedServerService(
  SharedPreferences prefs,
  SecretStore secrets,
) async => NoopEmbeddedServerService();

abstract class EmbeddedServerService {
  EmbeddedServerService({
    bool available = false,
    EmbeddedServerConfig config = const EmbeddedServerConfig(),
    EmbeddedServerStatus status = const EmbeddedServerStatus(),
  }) : viewModel = EmbeddedServerViewModel(
         available: available,
         runtime: EmbeddedServerRuntimeState.fromStatus(
           available: available,
           status: status,
         ),
         config: config,
         status: status,
       );

  final EmbeddedServerViewModel viewModel;

  bool get available => viewModel.available;

  EmbeddedServerConfig get config => viewModel.config;

  EmbeddedServerStatus get status => viewModel.status;

  EmbeddedServerRuntimeState get runtimeState => viewModel.runtime;

  EmbeddedRunState get phase => status.phase;

  @protected
  set availableState(bool value) => viewModel.applyRuntime(
    value
        ? runtimeState.copyWith(
            generation: runtimeState.generation + 1,
            lifecycle: embeddedLifecycleForStatus(status),
          )
        : runtimeState.copyWith(
            generation: runtimeState.generation + 1,
            lifecycle: const EmbeddedServerUnavailable(),
            poll: const EmbeddedServerPollDormant(),
          ),
  );

  @protected
  set configState(EmbeddedServerConfig value) => viewModel.config = value;

  @protected
  set statusState(EmbeddedServerStatus value) => viewModel.applyRuntime(
    runtimeState.copyWith(
      generation: runtimeState.generation + 1,
      lifecycle: runtimeState.available
          ? embeddedLifecycleForStatus(value)
          : const EmbeddedServerUnavailable(),
      poll: const EmbeddedServerPollDormant(),
    ),
    status: value,
  );

  @protected
  set embeddedRuntimeState(EmbeddedServerRuntimeState value) =>
      viewModel.applyRuntime(value);

  Future<void> updateConfig(EmbeddedServerConfig next);
  String generateToken();
  Future<void> start();
  Future<void> stop();
  Future<List<RegisteredPushToken>> registeredPushTokens();
  Future<PushTestResult> sendTestPush(String deviceToken);
  List<String> tailLogs([int n = 200]);

  void dispose() {}
}

class NoopEmbeddedServerService extends EmbeddedServerService {
  @override
  Future<void> updateConfig(EmbeddedServerConfig next) async {}

  @override
  String generateToken() => '';

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<List<RegisteredPushToken>> registeredPushTokens() async => const [];

  @override
  Future<PushTestResult> sendTestPush(String deviceToken) async =>
      const PushTestResult(sent: false);

  @override
  List<String> tailLogs([int n = 200]) => const [];
}
