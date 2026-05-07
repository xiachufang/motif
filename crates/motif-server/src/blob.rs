//! Blob transfer registry — control plane lives on the main `/ws`; data plane
//! is a separate `/blob/<id>` WebSocket per transfer (see `ws.rs`).
//!
//! M7 implementation. Read/write are both supported. transfer_id is one-shot:
//! after the data WS opens & closes, commit (write mode) finalizes; cancel or
//! TTL expiry frees the slot.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use dashmap::DashMap;
use motif_proto::common::UnixMs;
use motif_proto::error::{ErrorCode, RpcError};
use motif_proto::fs::*;
use parking_lot::Mutex;
use sha2::{Digest, Sha256};

use crate::session::Session;

const BLOB_TTL: Duration         = Duration::from_secs(300);
const MAX_PER_SESSION: usize     = 4;
const MAX_BLOB_BYTES: u64        = 200 * 1024 * 1024;

#[derive(Default)]
pub struct BlobRegistry {
    transfers: DashMap<String, Arc<BlobTransfer>>,
}

pub struct BlobTransfer {
    pub id:           String,
    pub session_id:   String,
    pub path:         PathBuf,
    pub mode:         BlobMode,
    pub created_at:   Instant,
    pub expected_sha: Option<String>,
    pub total_size:   Option<u64>,
    /// For read mode: cached file metadata.
    pub size:         Option<u64>,
    pub mime:         Option<String>,
    pub sha256:       Option<String>,
    /// Mutable state.
    pub state:        Mutex<BlobState>,
}

pub struct BlobState {
    pub tmp_file:    Option<PathBuf>,
    pub bytes_received: u64,
    pub running_hash: Sha256,
    pub completed:   bool,
}

impl BlobRegistry {
    pub fn new() -> Arc<Self> { Arc::new(Self::default()) }

    pub fn get(&self, id: &str) -> Option<Arc<BlobTransfer>> {
        // Lazy expiration check.
        let entry = self.transfers.get(id)?.clone();
        if entry.created_at.elapsed() > BLOB_TTL {
            drop(entry);
            self.transfers.remove(id);
            return None;
        }
        Some(self.transfers.get(id)?.clone())
    }

    pub fn count(&self) -> usize { self.transfers.len() }

    pub fn remove(&self, id: &str) -> Option<Arc<BlobTransfer>> {
        self.transfers.remove(id).map(|(_, v)| v)
    }

    pub fn insert(&self, t: Arc<BlobTransfer>) {
        self.transfers.insert(t.id.clone(), t);
    }
}

pub fn open(s: &Arc<Session>, _client_hint: &str, p: &OpenBlobParams) -> Result<OpenBlobResult, RpcError> {
    if s.blobs.count() >= MAX_PER_SESSION {
        return Err(RpcError::new(ErrorCode::BlobLimitReached, "concurrent blob transfer limit reached"));
    }
    let abs = crate::fs::resolve(&s.workdir, &p.path)?;

    let (size, mime, sha) = match p.mode {
        BlobMode::Read => {
            let meta = std::fs::metadata(&abs).map_err(crate::fs::io_to_rpc_err)?;
            if meta.len() > MAX_BLOB_BYTES {
                return Err(RpcError::new(ErrorCode::BlobTooLarge, format!("blob too large: {} bytes", meta.len())));
            }
            // Compute sha256 once at open. For very large files this is the price
            // of the integrity guarantee; M7's 200MB cap keeps this bounded.
            let bytes = std::fs::read(&abs).map_err(crate::fs::io_to_rpc_err)?;
            let sha   = sha256_hex(&bytes);
            let mime  = mime_guess::from_path(&abs).first_raw().map(String::from);
            (Some(meta.len()), mime, Some(sha))
        }
        BlobMode::Write => {
            if let Some(sz) = p.total_size {
                if sz > MAX_BLOB_BYTES {
                    return Err(RpcError::new(ErrorCode::BlobTooLarge, format!("blob too large: {sz} bytes")));
                }
            }
            (None, None, None)
        }
    };

    let id   = ulid::Ulid::new().to_string();
    let t    = Arc::new(BlobTransfer {
        id:           id.clone(),
        session_id:   s.id.clone(),
        path:         abs,
        mode:         p.mode,
        created_at:   Instant::now(),
        expected_sha: p.expected_sha256.clone(),
        total_size:   p.total_size,
        size,
        mime:         mime.clone(),
        sha256:       sha.clone(),
        state:        Mutex::new(BlobState {
            tmp_file:        None,
            bytes_received:  0,
            running_hash:    Sha256::new(),
            completed:       false,
        }),
    });
    s.blobs.insert(t);

    Ok(OpenBlobResult {
        transfer_id: id.clone(),
        blob_path:   format!("/blob/{}", id),
        expires_at:  now_ms() + BLOB_TTL.as_millis() as u64,
        size,
        mime,
        sha256:      sha,
    })
}

pub fn commit(s: &Arc<Session>, p: &CommitBlobParams) -> Result<CommitBlobResult, RpcError> {
    let t = s.blobs.get(&p.transfer_id)
        .ok_or_else(|| RpcError::new(ErrorCode::BlobNotFound, "transfer not found or expired"))?;
    if !matches!(t.mode, BlobMode::Write) {
        return Err(RpcError::invalid_request("commit only valid for write mode"));
    }

    let (tmp, sha) = {
        let st = t.state.lock();
        if !st.completed {
            return Err(RpcError::invalid_request("write WS not yet closed"));
        }
        let sha = hex::encode(st.running_hash.clone().finalize());
        (st.tmp_file.clone(), sha)
    };
    if let Some(expected) = &t.expected_sha {
        // Compare against pre-existing file (optimistic lock against external mutation).
        let current = if t.path.exists() {
            sha256_hex(&std::fs::read(&t.path).map_err(crate::fs::io_to_rpc_err)?)
        } else {
            sha256_hex(&[])
        };
        if &current != expected {
            return Err(RpcError::new(
                ErrorCode::Conflict,
                format!("file changed during transfer: current={current}, expected={expected}"),
            ));
        }
    }
    let Some(tmp_path) = tmp else {
        return Err(RpcError::internal("no tmp file recorded"));
    };

    if let Some(parent) = t.path.parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent).map_err(crate::fs::io_to_rpc_err)?;
        }
    }
    std::fs::rename(&tmp_path, &t.path).map_err(crate::fs::io_to_rpc_err)?;
    s.blobs.remove(&t.id);

    let path_str = path_relative(&s.workdir, &t.path);
    s.publish_event(|seq| motif_proto::event::Event::TreeChanged {
        paths: vec![path_str],
        seq,
    });
    if crate::git::workdir_is_repo(&s.workdir) {
        s.publish_event(|seq| motif_proto::event::Event::GitChanged { seq });
    }

    Ok(CommitBlobResult { sha256: sha })
}

pub fn cancel(s: &Arc<Session>, p: &CancelBlobParams) -> Result<crate::rpc::EmptyOk, RpcError> {
    if let Some(t) = s.blobs.remove(&p.transfer_id) {
        let st = t.state.lock();
        if let Some(tmp) = &st.tmp_file {
            let _ = std::fs::remove_file(tmp);
        }
    }
    Ok(crate::rpc::EmptyOk {})
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

pub(crate) fn path_relative(workdir: &std::path::Path, abs: &std::path::Path) -> String {
    abs.strip_prefix(workdir.canonicalize().unwrap_or_else(|_| workdir.to_path_buf()))
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| abs.display().to_string())
}

fn now_ms() -> UnixMs {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
