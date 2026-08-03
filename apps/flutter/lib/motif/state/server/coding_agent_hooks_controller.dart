import '../../models/coding_agent_hooks.dart';
import 'server_transport.dart';

class CodingAgentHooksController {
  const CodingAgentHooksController(this._transport);

  final ServerTransport _transport;

  Future<CodingAgentHooksStatus> status() => _call('agent_hooks.status');

  Future<CodingAgentHooksStatus> install(CodingAgent agent) =>
      _call('agent_hooks.install', {'agent': agent.name});

  Future<CodingAgentHooksStatus> uninstall(CodingAgent agent) =>
      _call('agent_hooks.uninstall', {'agent': agent.name});

  Future<CodingAgentHooksStatus> _call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final body = await _transport.call(method, params);
    return CodingAgentHooksStatus.fromJson(body);
  }
}
