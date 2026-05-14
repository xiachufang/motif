//! Git operations: status / diff / diffSummary by forking the `git` CLI.

use std::path::Path;
use std::process::{Command, Stdio};

use motif_proto::error::{ErrorCode, RpcError};
use motif_proto::git::*;

pub fn workdir_is_repo(workdir: &Path) -> bool {
    Command::new("git")
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(workdir)
        .args(["rev-parse", "--is-inside-work-tree"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn ensure_repo(workdir: &Path) -> Result<(), RpcError> {
    if !workdir_is_repo(workdir) {
        return Err(RpcError::new(
            ErrorCode::NotAGitRepo,
            "not a git repository",
        ));
    }
    Ok(())
}

pub fn status(workdir: &Path) -> Result<StatusResult, RpcError> {
    ensure_repo(workdir)?;
    // `--untracked-files=all` makes git enumerate each untracked file
    // individually instead of collapsing whole directories into a single
    // `? path/` entry. Aligns the status list with what `git diff` produces
    // (which already shows per-file patches via `git ls-files --others`),
    // and gives the UI real file paths to click on / build a tree from.
    // `--no-optional-locks` keeps git from rewriting `.git/index` during
    // racy-stat refresh. Without it, every `git status` from this RPC bumps
    // the index mtime, fswatch sees that as a tree change, fires
    // `git.changed`, the client re-calls `git.status`, and we loop forever.
    let out = Command::new("git")
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(workdir)
        .args([
            "status",
            "--porcelain=v2",
            "--branch",
            "--untracked-files=all",
        ])
        .output()
        .map_err(|e| RpcError::internal(format!("spawn git: {e}")))?;
    if !out.status.success() {
        return Err(RpcError::internal(format!(
            "git status: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut branch = None;
    let mut ahead = 0u32;
    let mut behind = 0u32;
    let mut files = Vec::new();
    for line in stdout.lines() {
        if let Some(rest) = line.strip_prefix("# branch.head ") {
            branch = Some(rest.to_string());
        } else if let Some(rest) = line.strip_prefix("# branch.ab ") {
            // "+1 -2"
            let mut it = rest.split_whitespace();
            if let Some(a) = it.next() {
                if let Some(s) = a.strip_prefix('+') {
                    ahead = s.parse().unwrap_or(0);
                }
            }
            if let Some(b) = it.next() {
                if let Some(s) = b.strip_prefix('-') {
                    behind = s.parse().unwrap_or(0);
                }
            }
        } else if line.starts_with("1 ") || line.starts_with("2 ") {
            // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
            // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<orig>
            let parts: Vec<&str> = line.splitn(9, ' ').collect();
            if parts.len() >= 9 {
                let xy = parts[1];
                let path = if line.starts_with("2 ") {
                    // skip the score field; path starts after the next space
                    let after_score = parts[8];
                    let mut sp = after_score.splitn(2, ' ');
                    sp.next(); // <Xscore>
                    let rest = sp.next().unwrap_or("");
                    rest.split('\t').next().unwrap_or(rest).to_string()
                } else {
                    parts[8].to_string()
                };
                let (staged, unstaged) = parse_xy(xy);
                files.push(GitFile {
                    path,
                    staged,
                    unstaged,
                });
            }
        } else if line.starts_with("? ") {
            files.push(GitFile {
                path: line[2..].to_string(),
                staged: GitFileStatus::Untracked,
                unstaged: GitFileStatus::Untracked,
            });
        } else if line.starts_with("! ") {
            files.push(GitFile {
                path: line[2..].to_string(),
                staged: GitFileStatus::Ignored,
                unstaged: GitFileStatus::Ignored,
            });
        }
    }
    Ok(StatusResult {
        branch,
        ahead,
        behind,
        files,
    })
}

fn parse_xy(xy: &str) -> (GitFileStatus, GitFileStatus) {
    let bytes = xy.as_bytes();
    let staged = if bytes.len() > 0 {
        code_to_status(bytes[0] as char)
    } else {
        GitFileStatus::Unmodified
    };
    let unstaged = if bytes.len() > 1 {
        code_to_status(bytes[1] as char)
    } else {
        GitFileStatus::Unmodified
    };
    (staged, unstaged)
}

fn code_to_status(c: char) -> GitFileStatus {
    match c {
        '.' | ' ' => GitFileStatus::Unmodified,
        'M' => GitFileStatus::Modified,
        'A' => GitFileStatus::Added,
        'D' => GitFileStatus::Deleted,
        'R' => GitFileStatus::Renamed,
        'C' => GitFileStatus::Copied,
        'U' => GitFileStatus::Conflicted,
        '?' => GitFileStatus::Untracked,
        '!' => GitFileStatus::Ignored,
        _ => GitFileStatus::Unmodified,
    }
}

pub fn diff(workdir: &Path, p: &DiffParams) -> Result<DiffResult, RpcError> {
    ensure_repo(workdir)?;
    let mut cmd = Command::new("git");
    cmd.arg("--no-optional-locks")
        .arg("-C")
        .arg(workdir)
        .arg("diff");
    if p.staged {
        cmd.arg("--staged");
    }
    if let Some(path) = &p.path {
        cmd.arg("--").arg(path);
    }
    let out = cmd
        .output()
        .map_err(|e| RpcError::internal(format!("spawn git: {e}")))?;
    if !out.status.success() {
        return Err(RpcError::internal(format!(
            "git diff: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let mut patch = String::from_utf8_lossy(&out.stdout).into_owned();

    // `git diff` (unstaged) omits untracked files by design. Synthesize a
    // "new file" patch for each one so the UI can show it inline. Only
    // applies to the unstaged view — `--staged` looks at the index, which
    // by definition can't contain untracked content.
    if !p.staged {
        for rel in list_untracked(workdir, p.path.as_deref())? {
            if let Some(chunk) = diff_untracked_file(workdir, &rel) {
                if !patch.is_empty() && !patch.ends_with('\n') {
                    patch.push('\n');
                }
                patch.push_str(&chunk);
            }
        }
    }

    Ok(DiffResult { patch })
}

/// Untracked paths, respecting .gitignore. NUL-separated to handle paths
/// with spaces / non-utf8.
fn list_untracked(workdir: &Path, path_filter: Option<&str>) -> Result<Vec<String>, RpcError> {
    let mut cmd = Command::new("git");
    cmd.arg("--no-optional-locks").arg("-C").arg(workdir).args([
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
    ]);
    if let Some(p) = path_filter {
        cmd.arg("--").arg(p);
    }
    let out = cmd
        .output()
        .map_err(|e| RpcError::internal(format!("spawn git: {e}")))?;
    if !out.status.success() {
        return Err(RpcError::internal(format!(
            "git ls-files: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .split('\0')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect())
}

/// Build a unified-diff patch chunk for one untracked file by diffing it
/// against /dev/null. `--no-index` makes git treat the two args as raw
/// paths rather than refs; exit code 1 means "differences found" (the
/// expected case here, not an error). We omit `--binary` so binary files
/// produce a small "Binary files differ" note instead of a base85 blob.
fn diff_untracked_file(workdir: &Path, rel: &str) -> Option<String> {
    let out = Command::new("git")
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(workdir)
        .args(["diff", "--no-index", "--no-color", "--", "/dev/null", rel])
        .output()
        .ok()?;
    let code = out.status.code().unwrap_or(-1);
    if code != 0 && code != 1 {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

pub fn diff_summary(workdir: &Path, p: &DiffParams) -> Result<DiffSummaryResult, RpcError> {
    ensure_repo(workdir)?;
    let mut cmd = Command::new("git");
    cmd.arg("--no-optional-locks")
        .arg("-C")
        .arg(workdir)
        .arg("diff")
        .arg("--numstat");
    if p.staged {
        cmd.arg("--staged");
    }
    if let Some(path) = &p.path {
        cmd.arg("--").arg(path);
    }
    let out = cmd
        .output()
        .map_err(|e| RpcError::internal(format!("spawn git: {e}")))?;
    if !out.status.success() {
        return Err(RpcError::internal(format!(
            "git diff --numstat: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    let mut files = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let mut it = line.split_whitespace();
        let add = it.next().and_then(|s| s.parse::<u32>().ok()).unwrap_or(0);
        let del = it.next().and_then(|s| s.parse::<u32>().ok()).unwrap_or(0);
        let path = it.collect::<Vec<_>>().join(" ");
        if path.is_empty() {
            continue;
        }
        files.push(DiffSummaryFile {
            path,
            additions: add,
            deletions: del,
        });
    }
    Ok(DiffSummaryResult { files })
}
