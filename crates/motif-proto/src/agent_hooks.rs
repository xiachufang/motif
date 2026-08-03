//! `agent_hooks.*` request/response types.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CodingAgent {
    Claude,
    Codex,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StatusParams {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangeParams {
    pub agent: CodingAgent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentHookState {
    pub installed: bool,
    pub configured: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusResult {
    pub claude: AgentHookState,
    pub codex: AgentHookState,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coding_agent_uses_lowercase_wire_names() {
        let params: ChangeParams =
            serde_json::from_value(serde_json::json!({"agent": "codex"})).unwrap();
        assert_eq!(params.agent, CodingAgent::Codex);
        assert_eq!(
            serde_json::to_value(ChangeParams {
                agent: CodingAgent::Claude,
            })
            .unwrap(),
            serde_json::json!({"agent": "claude"})
        );
    }
}
