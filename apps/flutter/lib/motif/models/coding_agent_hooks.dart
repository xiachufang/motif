enum CodingAgent {
  claude('Claude Code'),
  codex('Codex');

  const CodingAgent(this.label);

  final String label;
}

class CodingAgentHooksStatus {
  const CodingAgentHooksStatus({
    this.claudeInstalled = false,
    this.codexInstalled = false,
    bool? claudeConfigured,
    bool? codexConfigured,
  }) : claudeConfigured = claudeConfigured ?? claudeInstalled,
       codexConfigured = codexConfigured ?? codexInstalled;

  factory CodingAgentHooksStatus.fromJson(Map<String, Object?> json) {
    final claude = json['claude'];
    final codex = json['codex'];
    return CodingAgentHooksStatus(
      claudeInstalled: claude is Map && claude['installed'] == true,
      codexInstalled: codex is Map && codex['installed'] == true,
      claudeConfigured: claude is Map && claude['configured'] == true,
      codexConfigured: codex is Map && codex['configured'] == true,
    );
  }

  final bool claudeInstalled;
  final bool codexInstalled;
  final bool claudeConfigured;
  final bool codexConfigured;

  bool installed(CodingAgent agent) => switch (agent) {
    CodingAgent.claude => claudeInstalled,
    CodingAgent.codex => codexInstalled,
  };

  /// Whether the corresponding server-side config contains a Motif hook.
  bool configured(CodingAgent agent) => switch (agent) {
    CodingAgent.claude => claudeConfigured,
    CodingAgent.codex => codexConfigured,
  };
}
