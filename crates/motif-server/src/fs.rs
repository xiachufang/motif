//! File-system operations bound to a session's workdir.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use motif_proto::error::{ErrorCode, RpcError};
use motif_proto::fs::*;
use sha2::{Digest, Sha256};

use crate::session::Session;

/// Resolve a client-supplied path. If absolute, used as-is; if relative, joined
/// against `workdir`. We canonicalize so `..`/symlinks land somewhere sane, but
/// we no longer enforce a workdir prefix — the file tree pane is allowed to
/// follow the active PTY's cwd anywhere on disk (per design call: workdir is
/// not a security boundary, this server already runs as the user).
pub fn resolve(_workdir: &Path, path: &str) -> Result<PathBuf, RpcError> {
    // A leading `~` / `~/…` expands against $HOME (so the dir picker can start
    // at home, including before a session exists). All other paths must be
    // absolute.
    let candidate = match tilde_home(path) {
        Some(home) => home,
        None if Path::new(path).is_absolute() => PathBuf::from(path),
        None => {
            return Err(RpcError::invalid_params(format!(
                "path must be absolute: {path}"
            )))
        }
    };
    let resolved = if candidate.exists() {
        candidate.canonicalize().unwrap_or(candidate)
    } else {
        match candidate.parent() {
            Some(p) => p
                .canonicalize()
                .unwrap_or_else(|_| p.to_path_buf())
                .join(candidate.file_name().unwrap_or_default()),
            None => candidate,
        }
    };
    Ok(resolved)
}

/// Expand a leading `~` / `~/…` against `$HOME`. `None` when `rel` isn't a tilde
/// path (or `$HOME` is unset). `~user` is intentionally unsupported.
fn tilde_home(rel: &str) -> Option<PathBuf> {
    if rel == "~" {
        return std::env::var_os("HOME").map(PathBuf::from);
    }
    let rest = rel.strip_prefix("~/")?;
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(rest))
}

/// List a directory under `base_dir`. `base_dir` is the attached session's
/// workdir, or `$HOME` when browsing without a session (the dir picker before a
/// session exists). Absolute / `~` paths in `p.path` ignore `base_dir`.
pub fn tree(base_dir: &Path, p: &TreeParams) -> Result<TreeResult, RpcError> {
    let dir = resolve(base_dir, &p.path)?;
    if !dir.is_dir() {
        return Err(RpcError::invalid_params(format!(
            "not a directory: {}",
            p.path
        )));
    }
    let mut entries = Vec::new();
    let depth = p.depth.max(1) as usize;
    for ent in walkdir::WalkDir::new(&dir)
        .min_depth(1)
        .max_depth(depth)
        .sort_by_file_name()
    {
        let ent = match ent {
            Ok(e) => e,
            Err(_) => continue,
        };
        let name = ent.file_name().to_string_lossy().to_string();
        if !p.show_hidden && name.starts_with('.') {
            continue;
        }
        let meta = match ent.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        let kind = if meta.is_dir() {
            FileType::Dir
        } else if meta.file_type().is_symlink() {
            FileType::Symlink
        } else {
            FileType::File
        };
        entries.push(TreeEntry {
            name,
            kind,
            size: if meta.is_file() { meta.len() } else { 0 },
            mtime: mtime_ms(&meta),
            git_status: None,
        });
    }
    Ok(TreeResult {
        path: p.path.clone(),
        entries,
    })
}

pub fn stat(s: &Session, p: &StatParams) -> Result<StatResult, RpcError> {
    let path = resolve(&s.workdir, &p.path)?;
    let meta = std::fs::metadata(&path).map_err(io_to_rpc_err)?;
    let kind = if meta.is_dir() {
        FileType::Dir
    } else if meta.file_type().is_symlink() {
        FileType::Symlink
    } else {
        FileType::File
    };
    Ok(StatResult {
        kind,
        size: if meta.is_file() { meta.len() } else { 0 },
        mtime: mtime_ms(&meta),
        git_status: None,
    })
}

pub fn read(s: &Session, p: &ReadParams) -> Result<ReadResult, RpcError> {
    let path = resolve(&s.workdir, &p.path)?;
    let meta = std::fs::metadata(&path).map_err(io_to_rpc_err)?;
    if meta.len() > p.max_bytes {
        return Err(RpcError::new(
            ErrorCode::FileTooLarge,
            format!("file is {} bytes, exceeds max {}", meta.len(), p.max_bytes),
        ));
    }
    let bytes = std::fs::read(&path).map_err(io_to_rpc_err)?;
    let sha = sha256_hex(&bytes);
    let binary = is_binary(&bytes);
    let mime = mime_guess::from_path(&path).first_raw().map(String::from);
    Ok(ReadResult {
        content_b64: BASE64.encode(&bytes),
        sha256: sha,
        truncated: false,
        binary,
        mime,
    })
}

pub fn write(s: &Session, p: &WriteParams) -> Result<WriteResult, RpcError> {
    let bytes = BASE64
        .decode(p.content_b64.as_bytes())
        .map_err(|e| RpcError::invalid_params(format!("bad base64: {e}")))?;
    write_bytes(s, &p.path, &bytes, p.expected_sha256.as_deref(), p.force)
}

/// Write raw bytes to `rel_path` (resolved against the session workdir),
/// applying the same optimistic-sha guard and parent-dir creation as the
/// base64 [`write`]. Shared by the JSON `fs.write` RPC and its binary
/// (`application/octet-stream`) variant, which skips base64 entirely.
pub fn write_bytes(
    s: &Session,
    rel_path: &str,
    bytes: &[u8],
    expected_sha256: Option<&str>,
    force: bool,
) -> Result<WriteResult, RpcError> {
    let path = resolve(&s.workdir, rel_path)?;

    if let Some(expected) = expected_sha256 {
        let current = if path.exists() {
            sha256_hex(&std::fs::read(&path).map_err(io_to_rpc_err)?)
        } else {
            sha256_hex(&[])
        };
        if current.as_str() != expected && !force {
            return Err(RpcError::new(
                ErrorCode::Conflict,
                format!("sha256 mismatch (current={current}, expected={expected})"),
            ));
        }
    }

    if let Some(parent) = path.parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent).map_err(io_to_rpc_err)?;
        }
    }
    std::fs::write(&path, bytes).map_err(io_to_rpc_err)?;
    Ok(WriteResult {
        sha256: sha256_hex(bytes),
    })
}

pub(crate) fn io_to_rpc_err(e: std::io::Error) -> RpcError {
    match e.kind() {
        ErrorKind::NotFound => RpcError::invalid_params(format!("not found: {e}")),
        ErrorKind::PermissionDenied => RpcError::internal(format!("permission denied: {e}")),
        _ => RpcError::internal(e.to_string()),
    }
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

fn is_binary(bytes: &[u8]) -> bool {
    let head = &bytes[..bytes.len().min(8192)];
    if head.contains(&0u8) {
        return true;
    }
    std::str::from_utf8(head).is_err()
}

fn mtime_ms(meta: &std::fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
