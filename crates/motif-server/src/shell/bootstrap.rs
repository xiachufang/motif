//! Materializes embedded shell bootstrap scripts to a per-PTY tmpdir
//! and injects the right command-line flags / env vars so the shell sources
//! them on startup. Coding-agent hooks are managed separately by
//! [`crate::agent_hooks`] and only consume the Motif environment set here.
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
    let unquoted = cmd
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .unwrap_or(cmd);
    let first = if Path::new(unquoted).is_file() {
        unquoted
    } else {
        cmd.split_whitespace().next().unwrap_or("")
    };
    let name = Path::new(first)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match name.as_str() {
        "bash" => ShellKind::Bash,
        "zsh" => ShellKind::Zsh,
        "fish" => ShellKind::Fish,
        "pwsh" | "pwsh.exe" | "powershell" | "powershell.exe" => ShellKind::PowerShell,
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
                write_zsh_user_startup_wrapper(dir.path(), ".zshenv")?;
                write_zsh_user_startup_wrapper(dir.path(), ".zprofile")?;
                write_zsh_user_startup_wrapper(dir.path(), ".zlogin")?;
                write_zsh_user_startup_wrapper(dir.path(), ".zlogout")?;
                target
            }
            ShellKind::Fish => {
                write_asset(dir.path(), "fish.fish")?;
                dir.path().join("fish.fish")
            }
            ShellKind::PowerShell => {
                write_asset(dir.path(), "powershell.ps1")?;
                dir.path().join("powershell.ps1")
            }
            ShellKind::Unknown => unreachable!("guarded above"),
        };
        let user_zdotdir = std::env::var_os("ZDOTDIR").map(PathBuf::from);

        Some(Self {
            kind,
            session_id: session_id.into(),
            dir,
            entry,
            user_zdotdir,
        })
    }

    /// Apply the bootstrap to a `portable-pty` CommandBuilder before it
    /// spawns. Sets shared env vars + the shell-specific injection flag.
    pub fn apply_to(&self, cb: &mut CommandBuilder) {
        cb.env("MOTIF_BOOTSTRAPPED", "1");
        cb.env("MOTIF_SHELL", shell_kind_str(self.kind));
        cb.env("MOTIF_SESSION_ID", &self.session_id);
        cb.env("MOTIF_BOOTSTRAP_DIR", self.dir.path().as_os_str());
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
            ShellKind::PowerShell => {
                let entry = self.entry.to_string_lossy().replace('\'', "''");
                cb.args([
                    "-NoLogo",
                    "-NoExit",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-Command",
                    &format!(". '{entry}'"),
                ]);
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
        ShellKind::PowerShell => "powershell",
        ShellKind::Unknown => "unknown",
    }
}

fn write_asset(dir: &Path, name: &str) -> Option<()> {
    let bytes = ShellAssets::get(name)?.data;
    std::fs::write(dir.join(name), bytes).ok()?;
    Some(())
}

fn write_zsh_user_startup_wrapper(dir: &Path, name: &str) -> Option<()> {
    let wrapper = format!(
        r#"# Motif zsh startup wrapper. zsh decides whether this file is read;
# this only redirects the corresponding user file through the original ZDOTDIR.
__motif_bootstrap_zdotdir=${{MOTIF_BOOTSTRAP_DIR:-$ZDOTDIR}}
__motif_user_zdotdir=${{MOTIF_USER_ZDOTDIR:-$HOME}}
if [[ -n "$__motif_user_zdotdir" && -f "$__motif_user_zdotdir/{name}" ]]; then
    ZDOTDIR=$__motif_user_zdotdir source "$__motif_user_zdotdir/{name}"
    if [[ -n "$ZDOTDIR" && "$ZDOTDIR" != "$__motif_bootstrap_zdotdir" && "$ZDOTDIR" != "$__motif_user_zdotdir" ]]; then
        export MOTIF_USER_ZDOTDIR=$ZDOTDIR
    fi
fi
ZDOTDIR=$__motif_bootstrap_zdotdir
"#
    );
    std::fs::write(dir.join(name), wrapper).ok()?;
    Some(())
}

/// Pick a host directory under which to put each PTY's per-spawn tmpdir.
/// Prefers `$XDG_RUNTIME_DIR/motif/` on Unix and otherwise uses the platform
/// temporary directory. The actual name has a random suffix.
fn make_runtime_tmpdir() -> Option<tempfile::TempDir> {
    let base = crate::paths::runtime_dir("motif");
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
        assert!(matches!(detect("pwsh.exe"), ShellKind::PowerShell));
        assert!(matches!(detect("PowerShell.EXE"), ShellKind::PowerShell));
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
            "powershell.ps1",
            "motif-notify.sh",
            "motif-notify.ps1",
        ] {
            assert!(
                ShellAssets::get(name).is_some(),
                "missing embedded asset: {name}"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn zsh_login_bootstrap_sources_profile_before_rc_for_path_dependent_bindings() {
        use std::os::unix::fs::PermissionsExt;
        use std::process::Command;

        let Some(zsh) = find_on_path("zsh") else {
            return;
        };

        let boot = tempfile::tempdir().unwrap();
        let user = tempfile::tempdir().unwrap();
        let fake_bin = tempfile::tempdir().unwrap();

        let zsh_asset = ShellAssets::get("zsh.zsh").unwrap().data;
        std::fs::write(boot.path().join(".zshrc"), zsh_asset).unwrap();
        write_zsh_user_startup_wrapper(boot.path(), ".zprofile").unwrap();

        let fake_fzf = fake_bin.path().join("fzf");
        std::fs::write(
            &fake_fzf,
            r#"#!/bin/sh
if [ "${1:-}" = "--zsh" ]; then
  cat <<'EOF'
fzf-history-widget() { zle redisplay; }
zle -N fzf-history-widget
bindkey '^R' fzf-history-widget
EOF
fi
"#,
        )
        .unwrap();
        std::fs::set_permissions(&fake_fzf, std::fs::Permissions::from_mode(0o755)).unwrap();

        std::fs::write(
            user.path().join(".zprofile"),
            format!("export PATH={}:$PATH\n", zsh_quote(fake_bin.path())),
        )
        .unwrap();
        std::fs::write(
            user.path().join(".zshrc"),
            "(( $+commands[fzf] )) && source <(fzf --zsh)\n",
        )
        .unwrap();

        let output = Command::new(zsh)
            .env_clear()
            .env("HOME", user.path())
            .env("PATH", "/usr/bin:/bin")
            .env("ZDOTDIR", boot.path())
            .env("MOTIF_USER_ZDOTDIR", user.path())
            .arg("-l")
            .arg("-i")
            .arg("-c")
            .arg("bindkey '^R'; whence -w fzf-history-widget")
            .output()
            .unwrap();

        assert!(
            output.status.success(),
            "zsh probe failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("\"^R\" fzf-history-widget"),
            "expected Ctrl-R to be bound by fzf after .zprofile updated PATH, got:\n{stdout}",
        );
        assert!(
            stdout.contains("fzf-history-widget: function"),
            "expected fake fzf --zsh widget to be loaded, got:\n{stdout}",
        );
    }

    #[test]
    fn powershell_prepare_uses_ps1_bootstrap() {
        let Some(bs) = Bootstrap::prepare(ShellKind::PowerShell, "ps-1") else {
            return;
        };
        assert!(bs.entry.ends_with("powershell.ps1"));

        let mut command = CommandBuilder::new("powershell.exe");
        bs.apply_to(&mut command);
        let argv: Vec<_> = command
            .get_argv()
            .iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert!(argv.iter().any(|arg| arg == "-NoExit"));
        assert!(argv.iter().any(|arg| arg.contains("powershell.ps1")));
        assert_eq!(
            command.get_env("MOTIF_SHELL").and_then(|v| v.to_str()),
            Some("powershell")
        );
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

    #[cfg(unix)]
    fn find_on_path(name: &str) -> Option<PathBuf> {
        let path = std::env::var_os("PATH")?;
        std::env::split_paths(&path)
            .map(|dir| dir.join(name))
            .find(|candidate| candidate.is_file())
    }

    #[cfg(unix)]
    fn zsh_quote(path: &Path) -> String {
        format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
    }
}
