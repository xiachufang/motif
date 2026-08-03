import '../../models/coding_agent_hooks.dart';
import '../persistence/stores.dart';
import 'coding_agent_hooks_controller.dart';

/// Claims the one-time client prompt for one agent on one server. The remote
/// config entry is authoritative: if motifd reports the hook there, the prompt
/// is recorded as handled without being shown.
Future<bool> claimCodingAgentHookPrompt({
  required CodingAgentHooksController controller,
  required TerminalSettingsStore promptStore,
  required String serverId,
  required CodingAgent agent,
}) async {
  if (promptStore.codingAgentHookPromptShown(serverId, agent)) return false;
  final status = await controller.status();
  if (promptStore.codingAgentHookPromptShown(serverId, agent)) return false;
  await promptStore.markCodingAgentHookPromptShown(serverId, agent);
  return !status.configured(agent);
}
