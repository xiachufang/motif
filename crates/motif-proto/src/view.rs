//! Tab/view abstraction. The session owns an ordered list of "views" plus
//! a single active view id. Every client mirrors that state — closing a tab
//! anywhere removes it everywhere; clicking a tab anywhere makes it the
//! active one for everyone. Pty views are auto-managed alongside the PTY
//! pool; preview/diff/image views are user-opened.

use serde::{Deserialize, Serialize};

use crate::common::{PtyId, UnixMs};

pub type ViewId = String; // ULID

/// A view is the identity of a tab. Content (file bytes, diff patch, image
/// blob) is fetched fresh by each client based on the spec; the server only
/// tracks "what's open".
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum ViewSpec {
    Pty {
        pty_id: PtyId,
    },
    Preview {
        path: String,
    },
    Diff {
        #[serde(default)]
        staged: bool,
        #[serde(default)]
        path: Option<String>,
    },
    Image {
        path: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ViewInfo {
    pub id: ViewId,
    pub spec: ViewSpec,
    pub created_at: UnixMs,
}

// ────────────────────────────────────── view.open

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenParams {
    pub spec: ViewSpec,
    /// If true (default), make this view the active one immediately on
    /// every client. False is useful for "open but don't steal focus".
    #[serde(default = "default_true")]
    pub activate: bool,
}
fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenResult {
    pub view: ViewInfo,
}

// ────────────────────────────────────── view.close

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloseParams {
    pub view_id: ViewId,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CloseResult {}

// ────────────────────────────────────── view.activate

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivateParams {
    /// `None` means "no active view" (rare; used after the last view closes).
    pub view_id: Option<ViewId>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ActivateResult {}

// ────────────────────────────────────── view.move
//
// Reorder a single view to `to_index`, clamping to the bounds of the current
// view list. The server broadcasts the post-move order via `view.moved` so
// every attached client can re-render without re-deriving it from the action.

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MoveParams {
    pub view_id: ViewId,
    pub to_index: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MoveResult {}
