//! Persistent Claude Code and Codex notification-hook management.
//!
//! The hook definitions are user-global because neither agent has a terminal-
//! scoped persistent config layer. The installed runner is nevertheless inert
//! outside Motif: it requires the shell-bootstrap/session environment and a
//! live authenticated hook-ingress endpoint before it reads or forwards stdin.

use std::ffi::OsString;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock};

use anyhow::{bail, Context};
use serde::Serialize;
use serde_json::{json, Map, Value};

const CLAUDE_EVENTS: &[&str] = &["Notification", "Stop"];
const CODEX_EVENTS: &[&str] = &["Stop"];
static AGENT_HOOKS_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

#[cfg(windows)]
const RUNNER_FILE: &str = "motif-notify.ps1";
#[cfg(not(windows))]
const RUNNER_FILE: &str = "motif-notify.sh";

#[cfg(windows)]
const RUNNER_BYTES: &[u8] = include_bytes!("../assets/shell/motif-notify.ps1");
#[cfg(not(windows))]
const RUNNER_BYTES: &[u8] = include_bytes!("../assets/shell/motif-notify.sh");

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AgentHookState {
    pub installed: bool,
    /// At least one matching Motif handler exists, even if the installation is
    /// incomplete or its runner file is missing.
    pub configured: bool,
    pub config_path: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AgentHooksStatus {
    pub claude: AgentHookState,
    pub codex: AgentHookState,
    pub runner_path: String,
}

/// Coding agent whose Motif notification hook should be changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodingAgent {
    Claude,
    Codex,
}

#[derive(Debug, Clone)]
struct Locations {
    claude_config: PathBuf,
    codex_config: PathBuf,
    runner: PathBuf,
}

impl Locations {
    fn discover() -> anyhow::Result<Self> {
        let home = crate::paths::home_dir()
            .context("cannot determine the current user's home directory")?;
        let data = crate::paths::data_dir()
            .context("cannot determine the current user's data directory")?;
        let claude_dir = non_empty_env("CLAUDE_CONFIG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".claude"));
        let codex_dir = non_empty_env("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"));
        Ok(Self {
            claude_config: claude_dir.join("settings.json"),
            codex_config: codex_dir.join("hooks.json"),
            runner: data.join("motif").join("hooks").join(RUNNER_FILE),
        })
    }
}

fn non_empty_env(name: &str) -> Option<OsString> {
    std::env::var_os(name).filter(|value| !value.is_empty())
}

fn operation_guard() -> MutexGuard<'static, ()> {
    AGENT_HOOKS_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Inspect both user-level hook files without modifying them.
pub fn status() -> anyhow::Result<AgentHooksStatus> {
    let _guard = operation_guard();
    status_at(&Locations::discover()?)
}

/// Install or repair the Motif hook in Claude Code and Codex user config.
/// Existing settings and unrelated hooks are preserved.
pub fn install() -> anyhow::Result<AgentHooksStatus> {
    let _guard = operation_guard();
    install_at(&Locations::discover()?)
}

/// Remove only Motif-managed hook handlers from both agents. Existing settings
/// and unrelated hooks are preserved.
pub fn uninstall() -> anyhow::Result<AgentHooksStatus> {
    let _guard = operation_guard();
    uninstall_at(&Locations::discover()?)
}

/// Install or repair only the selected coding agent's Motif hook.
pub fn install_agent(agent: CodingAgent) -> anyhow::Result<AgentHooksStatus> {
    let _guard = operation_guard();
    install_agent_at(&Locations::discover()?, agent)
}

/// Remove only the selected coding agent's Motif hook.
pub fn uninstall_agent(agent: CodingAgent) -> anyhow::Result<AgentHooksStatus> {
    let _guard = operation_guard();
    uninstall_agent_at(&Locations::discover()?, agent)
}

fn status_at(locations: &Locations) -> anyhow::Result<AgentHooksStatus> {
    let command = hook_command(&locations.runner);
    let claude = read_json_object(&locations.claude_config)?;
    let codex = read_json_object(&locations.codex_config)?;
    Ok(status_from_roots(locations, &command, &claude, &codex)?)
}

fn install_at(locations: &Locations) -> anyhow::Result<AgentHooksStatus> {
    let command = hook_command(&locations.runner);
    // Parse and validate both files before writing either one. A malformed user
    // config must never be replaced with a generated document.
    let mut claude = read_json_object(&locations.claude_config)?;
    let mut codex = read_json_object(&locations.codex_config)?;
    validate_events(&claude, CLAUDE_EVENTS, &locations.claude_config)?;
    validate_events(&codex, CODEX_EVENTS, &locations.codex_config)?;

    install_runner(&locations.runner)?;
    for event in CLAUDE_EVENTS {
        add_handler(&mut claude, event, &command)?;
    }
    for event in CODEX_EVENTS {
        add_handler(&mut codex, event, &command)?;
    }
    write_json_object(&locations.claude_config, &claude)?;
    write_json_object(&locations.codex_config, &codex)?;
    status_from_roots(locations, &command, &claude, &codex)
}

fn uninstall_at(locations: &Locations) -> anyhow::Result<AgentHooksStatus> {
    let command = hook_command(&locations.runner);
    let mut claude = read_json_object(&locations.claude_config)?;
    let mut codex = read_json_object(&locations.codex_config)?;
    validate_events(&claude, CLAUDE_EVENTS, &locations.claude_config)?;
    validate_events(&codex, CODEX_EVENTS, &locations.codex_config)?;

    let claude_changed = remove_handlers(&mut claude, CLAUDE_EVENTS, &command)?;
    let codex_changed = remove_handlers(&mut codex, CODEX_EVENTS, &command)?;
    if claude_changed {
        write_json_object(&locations.claude_config, &claude)?;
    }
    if codex_changed {
        write_json_object(&locations.codex_config, &codex)?;
    }
    let status = status_from_roots(locations, &command, &claude, &codex)?;
    if !status.claude.installed && !status.codex.installed {
        match std::fs::remove_file(&locations.runner) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("remove hook runner {}", locations.runner.display()));
            }
        }
    }
    Ok(status)
}

fn install_agent_at(locations: &Locations, agent: CodingAgent) -> anyhow::Result<AgentHooksStatus> {
    let command = hook_command(&locations.runner);
    let mut claude = read_json_object(&locations.claude_config)?;
    let mut codex = read_json_object(&locations.codex_config)?;

    let (root, events, path) = match agent {
        CodingAgent::Claude => (&mut claude, CLAUDE_EVENTS, &locations.claude_config),
        CodingAgent::Codex => (&mut codex, CODEX_EVENTS, &locations.codex_config),
    };
    validate_events(root, events, path)?;
    install_runner(&locations.runner)?;
    for event in events {
        add_handler(root, event, &command)?;
    }
    write_json_object(path, root)?;

    status_from_roots(locations, &command, &claude, &codex)
}

fn uninstall_agent_at(
    locations: &Locations,
    agent: CodingAgent,
) -> anyhow::Result<AgentHooksStatus> {
    let command = hook_command(&locations.runner);
    let mut claude = read_json_object(&locations.claude_config)?;
    let mut codex = read_json_object(&locations.codex_config)?;

    let (root, events, path) = match agent {
        CodingAgent::Claude => (&mut claude, CLAUDE_EVENTS, &locations.claude_config),
        CodingAgent::Codex => (&mut codex, CODEX_EVENTS, &locations.codex_config),
    };
    validate_events(root, events, path)?;
    if remove_handlers(root, events, &command)? {
        write_json_object(path, root)?;
    }

    let status = status_from_roots(locations, &command, &claude, &codex)?;
    if !status.claude.configured && !status.codex.configured {
        match std::fs::remove_file(&locations.runner) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("remove hook runner {}", locations.runner.display()));
            }
        }
    }
    Ok(status)
}

fn status_from_roots(
    locations: &Locations,
    command: &str,
    claude: &Map<String, Value>,
    codex: &Map<String, Value>,
) -> anyhow::Result<AgentHooksStatus> {
    let runner_exists = locations.runner.is_file();
    let claude_configured = CLAUDE_EVENTS
        .iter()
        .any(|event| has_handler(claude, event, command).unwrap_or(false));
    let codex_configured = CODEX_EVENTS
        .iter()
        .any(|event| has_handler(codex, event, command).unwrap_or(false));
    Ok(AgentHooksStatus {
        claude: AgentHookState {
            installed: runner_exists
                && CLAUDE_EVENTS
                    .iter()
                    .all(|event| has_handler(claude, event, command).unwrap_or(false)),
            configured: claude_configured,
            config_path: locations.claude_config.to_string_lossy().into_owned(),
        },
        codex: AgentHookState {
            installed: runner_exists
                && CODEX_EVENTS
                    .iter()
                    .all(|event| has_handler(codex, event, command).unwrap_or(false)),
            configured: codex_configured,
            config_path: locations.codex_config.to_string_lossy().into_owned(),
        },
        runner_path: locations.runner.to_string_lossy().into_owned(),
    })
}

fn read_json_object(path: &Path) -> anyhow::Result<Map<String, Value>> {
    let raw = match std::fs::read(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
    };
    let value: Value = serde_json::from_slice(&raw)
        .with_context(|| format!("parse {} as JSON", path.display()))?;
    value
        .as_object()
        .cloned()
        .with_context(|| format!("{} must contain a JSON object", path.display()))
}

fn validate_events(root: &Map<String, Value>, events: &[&str], path: &Path) -> anyhow::Result<()> {
    let Some(hooks) = root.get("hooks") else {
        return Ok(());
    };
    let hooks = hooks
        .as_object()
        .with_context(|| format!("{}.hooks must be a JSON object", path.display()))?;
    for event in events {
        let Some(groups) = hooks.get(*event) else {
            continue;
        };
        let groups = groups
            .as_array()
            .with_context(|| format!("{}.hooks.{event} must be a JSON array", path.display()))?;
        for (group_index, group) in groups.iter().enumerate() {
            let group = group.as_object().with_context(|| {
                format!(
                    "{}.hooks.{event}[{group_index}] must be a JSON object",
                    path.display()
                )
            })?;
            let handlers = group
                .get("hooks")
                .and_then(Value::as_array)
                .with_context(|| {
                    format!(
                        "{}.hooks.{event}[{group_index}].hooks must be a JSON array",
                        path.display()
                    )
                })?;
            if handlers.iter().any(|handler| !handler.is_object()) {
                bail!(
                    "{}.hooks.{event}[{group_index}].hooks must contain JSON objects",
                    path.display()
                );
            }
        }
    }
    Ok(())
}

fn has_handler(root: &Map<String, Value>, event: &str, command: &str) -> Option<bool> {
    let groups = root.get("hooks")?.as_object()?.get(event)?.as_array()?;
    Some(groups.iter().any(|group| {
        group
            .as_object()
            .and_then(|group| group.get("hooks"))
            .and_then(Value::as_array)
            .is_some_and(|handlers| {
                handlers.iter().any(|handler| {
                    handler.get("type").and_then(Value::as_str) == Some("command")
                        && handler.get("command").and_then(Value::as_str) == Some(command)
                })
            })
    }))
}

fn hooks_object_mut(root: &mut Map<String, Value>) -> anyhow::Result<&mut Map<String, Value>> {
    let hooks = root
        .entry("hooks".to_string())
        .or_insert_with(|| Value::Object(Map::new()));
    hooks.as_object_mut().context("hooks must be a JSON object")
}

fn add_handler(root: &mut Map<String, Value>, event: &str, command: &str) -> anyhow::Result<bool> {
    if has_handler(root, event, command) == Some(true) {
        return Ok(false);
    }
    let hooks = hooks_object_mut(root)?;
    let groups = hooks
        .entry(event.to_string())
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .with_context(|| format!("hooks.{event} must be a JSON array"))?;
    groups.push(json!({
        "hooks": [{
            "type": "command",
            "command": command,
            "timeout": 5
        }]
    }));
    Ok(true)
}

fn remove_handlers(
    root: &mut Map<String, Value>,
    events: &[&str],
    command: &str,
) -> anyhow::Result<bool> {
    let Some(hooks_value) = root.get_mut("hooks") else {
        return Ok(false);
    };
    let hooks = hooks_value
        .as_object_mut()
        .context("hooks must be a JSON object")?;
    let mut changed = false;
    for event in events {
        let Some(groups_value) = hooks.get_mut(*event) else {
            continue;
        };
        let groups = groups_value
            .as_array_mut()
            .with_context(|| format!("hooks.{event} must be a JSON array"))?;
        let old_group_count = groups.len();
        for group in groups.iter_mut() {
            let handlers = group
                .as_object_mut()
                .and_then(|group| group.get_mut("hooks"))
                .and_then(Value::as_array_mut)
                .with_context(|| format!("hooks.{event} group must contain a hooks array"))?;
            let old_handler_count = handlers.len();
            handlers.retain(|handler| {
                !(handler.get("type").and_then(Value::as_str) == Some("command")
                    && handler.get("command").and_then(Value::as_str) == Some(command))
            });
            changed |= handlers.len() != old_handler_count;
        }
        groups.retain(|group| {
            group
                .get("hooks")
                .and_then(Value::as_array)
                .is_some_and(|handlers| !handlers.is_empty())
        });
        changed |= groups.len() != old_group_count;
    }
    hooks.retain(|_, value| !value.as_array().is_some_and(Vec::is_empty));
    if hooks.is_empty() {
        root.remove("hooks");
    }
    Ok(changed)
}

fn install_runner(path: &Path) -> anyhow::Result<()> {
    let parent = path
        .parent()
        .with_context(|| format!("{} has no parent directory", path.display()))?;
    std::fs::create_dir_all(parent)
        .with_context(|| format!("create hook runner directory {}", parent.display()))?;
    std::fs::write(path, RUNNER_BYTES)
        .with_context(|| format!("write hook runner {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("mark hook runner executable: {}", path.display()))?;
    }
    Ok(())
}

fn write_json_object(path: &Path, root: &Map<String, Value>) -> anyhow::Result<()> {
    let parent = path
        .parent()
        .with_context(|| format!("{} has no parent directory", path.display()))?;
    std::fs::create_dir_all(parent)
        .with_context(|| format!("create config directory {}", parent.display()))?;
    let mut bytes = serde_json::to_vec_pretty(&Value::Object(root.clone()))?;
    bytes.push(b'\n');
    let mut temp = tempfile::NamedTempFile::new_in(parent)
        .with_context(|| format!("create temporary config beside {}", path.display()))?;
    temp.write_all(&bytes)
        .with_context(|| format!("write temporary config for {}", path.display()))?;
    temp.as_file()
        .sync_all()
        .with_context(|| format!("sync temporary config for {}", path.display()))?;
    temp.persist(path)
        .map_err(|error| error.error)
        .with_context(|| format!("replace {}", path.display()))?;
    Ok(())
}

#[cfg(windows)]
fn hook_command(path: &Path) -> String {
    format!(
        "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{}\"",
        path.to_string_lossy()
    )
}

#[cfg(not(windows))]
fn hook_command(path: &Path) -> String {
    let path = path.to_string_lossy().replace('\'', "'\\''");
    format!("'{path}'")
}

#[cfg(test)]
mod tests {
    use super::*;

    const SH_RUNNER: &str = include_str!("../assets/shell/motif-notify.sh");
    const POWERSHELL_RUNNER: &str = include_str!("../assets/shell/motif-notify.ps1");

    fn locations(root: &Path) -> Locations {
        Locations {
            claude_config: root.join(".claude/settings.json"),
            codex_config: root.join(".codex/hooks.json"),
            runner: root.join("data/motif/hooks").join(RUNNER_FILE),
        }
    }

    #[test]
    fn runners_are_gated_to_motif_ptys() {
        for source in [SH_RUNNER, POWERSHELL_RUNNER] {
            assert!(source.contains("MOTIF_BOOTSTRAPPED"));
            assert!(source.contains("TERM_PROGRAM"));
            assert!(source.contains("MOTIF_SESSION_ID"));
        }
        assert!(SH_RUNNER.find("MOTIF_BOOTSTRAPPED").unwrap() < SH_RUNNER.find("curl").unwrap());
        assert!(
            POWERSHELL_RUNNER.find("MOTIF_BOOTSTRAPPED").unwrap()
                < POWERSHELL_RUNNER.find("Invoke-WebRequest").unwrap()
        );
    }

    #[test]
    fn install_and_uninstall_preserve_unrelated_hooks_and_settings() {
        let root = tempfile::tempdir().unwrap();
        let locations = locations(root.path());
        std::fs::create_dir_all(locations.claude_config.parent().unwrap()).unwrap();
        std::fs::create_dir_all(locations.codex_config.parent().unwrap()).unwrap();
        std::fs::write(
            &locations.claude_config,
            r#"{
  "theme": "dark",
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "existing-stop"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "existing-pre"}]}]
  }
}"#,
        )
        .unwrap();
        std::fs::write(
            &locations.codex_config,
            r#"{"description":"mine","hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"cleanup"}]}]}}"#,
        )
        .unwrap();

        let installed = install_at(&locations).unwrap();
        assert!(installed.claude.installed);
        assert!(installed.codex.installed);
        assert!(locations.runner.is_file());
        let runner = std::fs::read_to_string(&locations.runner).unwrap();
        assert!(runner.contains("MOTIF_BOOTSTRAPPED"));
        assert!(runner.contains("TERM_PROGRAM"));

        // Installation is idempotent.
        install_at(&locations).unwrap();
        let claude = read_json_object(&locations.claude_config).unwrap();
        let command = hook_command(&locations.runner);
        for event in CLAUDE_EVENTS {
            let count = claude["hooks"][*event]
                .as_array()
                .unwrap()
                .iter()
                .flat_map(|group| group["hooks"].as_array().unwrap())
                .filter(|handler| handler["command"] == command)
                .count();
            assert_eq!(count, 1, "duplicate handler for {event}");
        }

        let removed = uninstall_at(&locations).unwrap();
        assert!(!removed.claude.installed);
        assert!(!removed.codex.installed);
        assert!(!locations.runner.exists());
        let claude = read_json_object(&locations.claude_config).unwrap();
        assert_eq!(claude["theme"], "dark");
        assert_eq!(
            claude["hooks"]["Stop"][0]["hooks"][0]["command"],
            "existing-stop"
        );
        assert_eq!(
            claude["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
            "existing-pre"
        );
        let codex = read_json_object(&locations.codex_config).unwrap();
        assert_eq!(codex["description"], "mine");
        assert_eq!(
            codex["hooks"]["SessionEnd"][0]["hooks"][0]["command"],
            "cleanup"
        );
    }

    #[test]
    fn malformed_config_is_never_overwritten() {
        let root = tempfile::tempdir().unwrap();
        let locations = locations(root.path());
        std::fs::create_dir_all(locations.claude_config.parent().unwrap()).unwrap();
        std::fs::write(&locations.claude_config, "not json\n").unwrap();

        let error = install_at(&locations).unwrap_err().to_string();
        assert!(error.contains("parse"));
        assert_eq!(
            std::fs::read_to_string(&locations.claude_config).unwrap(),
            "not json\n"
        );
        assert!(!locations.runner.exists());
        assert!(!locations.codex_config.exists());
    }

    #[test]
    fn individual_agent_changes_do_not_touch_the_other_config() {
        let root = tempfile::tempdir().unwrap();
        let locations = locations(root.path());

        let claude_only = install_agent_at(&locations, CodingAgent::Claude).unwrap();
        assert!(claude_only.claude.configured);
        assert!(!claude_only.codex.configured);
        assert!(locations.claude_config.is_file());
        assert!(!locations.codex_config.exists());

        let both = install_agent_at(&locations, CodingAgent::Codex).unwrap();
        assert!(both.claude.configured);
        assert!(both.codex.configured);

        let claude_removed = uninstall_agent_at(&locations, CodingAgent::Claude).unwrap();
        assert!(!claude_removed.claude.configured);
        assert!(claude_removed.codex.configured);
        assert!(locations.runner.is_file());

        let all_removed = uninstall_agent_at(&locations, CodingAgent::Codex).unwrap();
        assert!(!all_removed.claude.configured);
        assert!(!all_removed.codex.configured);
        assert!(!locations.runner.exists());
    }
}
