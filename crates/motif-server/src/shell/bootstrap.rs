//! Materializes embedded shell bootstrap scripts to a per-PTY tmpdir
//! and injects the right command-line flags / env vars so the shell
//! sources them on startup.
//!
//! Scripts are baked into the binary via `rust-embed` and written out
//! when each PTY is created. The tmpdir is owned by `Bootstrap` and
//! cleaned up when it drops (so when the `Pty` drops, after the child
//! exits).

use std::path::{Path, PathBuf};

use motif_proto::pty::ShellKind;
use portable_pty::CommandBuilder;
use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "assets/shell/"]
struct ShellAssets;

/// Detect shell kind from a command line. Looks at the basename of the
/// first whitespace-separated token so `/usr/local/bin/zsh -l` resolves
/// the same as `zsh`.
pub fn detect(cmd: &str) -> ShellKind {
    let first = cmd.split_whitespace().next().unwrap_or("");
    match Path::new(first).file_name().and_then(|s| s.to_str()) {
        Some("bash") => ShellKind::Bash,
        Some("zsh") => ShellKind::Zsh,
        Some("fish") => ShellKind::Fish,
        _ => ShellKind::Unknown,
    }
}

/// Per-PTY bootstrap state. Holds the tmpdir alive for the child's
/// lifetime; dropping the `Pty` (which owns this) drops the tmpdir
/// which removes the materialized scripts.
pub struct Bootstrap {
    pub kind: ShellKind,
    pub session_id: String,
    /// RAII wrapper — directory is removed on drop.
    dir: tempfile::TempDir,
    /// Path of the entry-point script we hand the shell.
    entry: PathBuf,
    /// Original ZDOTDIR (zsh-only) so the wrapped rcfile can reach the
    /// user's real ~/.zshrc instead of recursing into our tmpdir.
    user_zdotdir: Option<PathBuf>,
    /// Generated Claude Code `--settings` file wiring the notify hook. The
    /// `claude` wrapper in each shell script passes this via `--settings` so
    /// the Notification/Stop hooks are provisioned without touching the user's
    /// `~/.claude/settings.json`.
    settings_path: PathBuf,
}

impl Bootstrap {
    /// Materialize bootstrap scripts. Returns `None` for shells we don't
    /// support, and when the user has disabled integration via
    /// `MOTIF_SHELL_INTEGRATION=0`.
    pub fn prepare(kind: ShellKind, session_id: &str) -> Option<Self> {
        if matches!(kind, ShellKind::Unknown) {
            return None;
        }
        if std::env::var("MOTIF_SHELL_INTEGRATION").as_deref() == Ok("0") {
            return None;
        }

        let dir = make_runtime_tmpdir()?;
        let entry = match kind {
            ShellKind::Bash => {
                write_asset(dir.path(), "bash.sh")?;
                write_asset(dir.path(), "bash-preexec.sh")?;
                dir.path().join("bash.sh")
            }
            ShellKind::Zsh => {
                // ZDOTDIR mode: zsh expects the file named exactly `.zshrc`.
                let bytes = ShellAssets::get("zsh.zsh")?.data;
                let target = dir.path().join(".zshrc");
                std::fs::write(&target, bytes).ok()?;
                target
            }
            ShellKind::Fish => {
                write_asset(dir.path(), "fish.fish")?;
                dir.path().join("fish.fish")
            }
            ShellKind::Unknown => unreachable!("guarded above"),
        };
        let user_zdotdir = std::env::var_os("ZDOTDIR").map(PathBuf::from);

        // Materialize the Claude Code notify hook + a settings file that wires
        // it. The settings file references the notify script by absolute path,
        // so it's generated per-PTY rather than embedded.
        write_asset_executable(dir.path(), "motif-notify.sh")?;
        let notify = dir.path().join("motif-notify.sh");
        let settings_path = dir.path().join("settings.json");
        let settings = serde_json::json!({
            "hooks": {
                "Notification": [
                    { "hooks": [ { "type": "command", "command": notify.to_string_lossy() } ] }
                ],
                "Stop": [
                    { "hooks": [ { "type": "command", "command": notify.to_string_lossy() } ] }
                ]
            }
        });
        std::fs::write(&settings_path, serde_json::to_vec_pretty(&settings).ok()?).ok()?;

        Some(Self {
            kind,
            session_id: session_id.into(),
            dir,
            entry,
            user_zdotdir,
            settings_path,
        })
    }

    /// Apply the bootstrap to a `portable-pty` CommandBuilder before it
    /// spawns. Sets shared env vars + the shell-specific injection flag.
    pub fn apply_to(&self, cb: &mut CommandBuilder) {
        cb.env("MOTIF_BOOTSTRAPPED", "1");
        cb.env("MOTIF_SHELL", shell_kind_str(self.kind));
        cb.env("MOTIF_SESSION_ID", &self.session_id);
        cb.env("MOTIF_BOOTSTRAP_DIR", self.dir.path().as_os_str());
        // The `claude` wrapper (defined in each shell script) only kicks in
        // when MOTIF_HOOK_SOCK is also present (i.e. push is enabled); see the
        // wrapper guards. We always set this so the wrapper has the path ready.
        cb.env("MOTIF_CLAUDE_SETTINGS", self.settings_path.as_os_str());

        match self.kind {
            ShellKind::Bash => {
                // --rcfile must be a separate arg from the path on bash 5+.
                cb.arg("--rcfile");
                cb.arg(self.entry.as_os_str());
            }
            ShellKind::Zsh => {
                cb.env("ZDOTDIR", self.dir.path().as_os_str());
                if let Some(user) = &self.user_zdotdir {
                    cb.env("MOTIF_USER_ZDOTDIR", user.as_os_str());
                }
            }
            ShellKind::Fish => {
                cb.arg("--init-command");
                cb.arg(format!("source {}", self.entry.display()));
            }
            ShellKind::Unknown => {} // unreachable — Bootstrap was None above
        }
    }
}

fn shell_kind_str(k: ShellKind) -> &'static str {
    match k {
        ShellKind::Bash => "bash",
        ShellKind::Zsh => "zsh",
        ShellKind::Fish => "fish",
        ShellKind::Unknown => "unknown",
    }
}

fn write_asset(dir: &Path, name: &str) -> Option<()> {
    let bytes = ShellAssets::get(name)?.data;
    std::fs::write(dir.join(name), bytes).ok()?;
    Some(())
}

/// Like [`write_asset`] but marks the file executable (0700) on Unix — used
/// for `motif-notify.sh`, which Claude Code execs as a hook command.
fn write_asset_executable(dir: &Path, name: &str) -> Option<()> {
    write_asset(dir, name)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(
            dir.join(name),
            std::fs::Permissions::from_mode(0o700),
        );
    }
    Some(())
}

/// Pick a host directory under which to put each PTY's per-spawn tmpdir.
/// Prefers `$XDG_RUNTIME_DIR/motif/` (user-owned tmpfs on Linux); falls
/// back to `$TMPDIR`, then `/tmp`. The actual tmpdir name has a random
/// suffix from `tempfile::Builder`.
fn make_runtime_tmpdir() -> Option<tempfile::TempDir> {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(|x| Path::new(&x).join("motif"))
        .or_else(|| std::env::var_os("TMPDIR").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    std::fs::create_dir_all(&base).ok()?;
    tempfile::Builder::new()
        .prefix("motif-shell-")
        .tempdir_in(base)
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_resolves_path_basenames() {
        assert!(matches!(detect("/bin/bash"), ShellKind::Bash));
        assert!(matches!(detect("/usr/local/bin/zsh -l"), ShellKind::Zsh));
        assert!(matches!(detect("fish"), ShellKind::Fish));
        assert!(matches!(
            detect("/opt/homebrew/bin/fish --foo"),
            ShellKind::Fish
        ));
        assert!(matches!(detect("/bin/sh"), ShellKind::Unknown));
        assert!(matches!(detect(""), ShellKind::Unknown));
    }

    #[test]
    fn assets_embed_resolves_all_scripts() {
        // Catches a forgotten `assets/shell/` file at compile time —
        // rust-embed won't fail to build, but the asset will be missing.
        for name in [
            "bash.sh",
            "bash-preexec.sh",
            "zsh.zsh",
            "fish.fish",
            "motif-notify.sh",
        ] {
            assert!(
                ShellAssets::get(name).is_some(),
                "missing embedded asset: {name}"
            );
        }
    }

    #[test]
    fn prepare_generates_claude_notify_settings() {
        // Don't touch MOTIF_SHELL_INTEGRATION here — `prepare_skipped_when_env_disabled`
        // toggles it and tests share the process env. If a concurrent test has
        // it disabled at this instant, prepare returns None; just skip then.
        let Some(bs) = Bootstrap::prepare(ShellKind::Bash, "sh-1") else {
            return;
        };
        // Notify script materialized + executable.
        let notify = bs.dir.path().join("motif-notify.sh");
        assert!(notify.exists(), "motif-notify.sh should be materialized");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&notify).unwrap().permissions().mode();
            assert!(mode & 0o100 != 0, "notify script should be executable");
        }
        // Settings file wires both hooks at the notify script.
        let raw = std::fs::read_to_string(&bs.settings_path).unwrap();
        let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
        for ev in ["Notification", "Stop"] {
            let cmd = v["hooks"][ev][0]["hooks"][0]["command"]
                .as_str()
                .unwrap_or_default();
            assert!(
                cmd.ends_with("motif-notify.sh"),
                "{ev} hook command should point at the notify script, got {cmd:?}"
            );
        }
    }

    #[test]
    fn prepare_skipped_when_env_disabled() {
        // Snapshot + restore so we don't bleed into other tests.
        let prev = std::env::var_os("MOTIF_SHELL_INTEGRATION");
        std::env::set_var("MOTIF_SHELL_INTEGRATION", "0");
        let bs = Bootstrap::prepare(ShellKind::Bash, "test-session");
        match prev {
            Some(v) => std::env::set_var("MOTIF_SHELL_INTEGRATION", v),
            None => std::env::remove_var("MOTIF_SHELL_INTEGRATION"),
        }
        assert!(
            bs.is_none(),
            "MOTIF_SHELL_INTEGRATION=0 should skip prepare"
        );
    }
}
