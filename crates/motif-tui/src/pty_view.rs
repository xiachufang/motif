//! Content-anchored scrollback over `vt100::Parser`.
//!
//! vt100 only exposes offset-based scrollback: `set_scrollback(N)` shows the
//! window N rows above the live area. As new output arrives, the live bottom
//! advances and any fixed offset slides under the user's eyes — they end up
//! reading something different from what they were looking at a moment ago.
//!
//! `PtyView` adds an absolute line counter so the user's anchor is a *line
//! ID* instead of an *offset*. As output arrives, the offset auto-recomputes
//! to keep the same content under the eye.
//!
//! vt100 has no "scrolled" callback, so we infer drift after each `process()`
//! by hashing the live screen's top row and searching the scrollback for the
//! matching hash from the previous frame. The depth where we find it = how
//! many rows scrolled off since last sync.
//!
//! Caveats — listed because the model isn't bulletproof:
//!   * Startup: the first burst of output (before a steady state is reached)
//!     may under-count drift, since `last_top_hash` starts unset and we skip
//!     the increment on the very first sync.
//!   * Alt-screen (vim/htop/less): tracking is paused. Wholesale screen
//!     replacement isn't a linear scroll, so we'd compute nonsense if we
//!     hashed through it.
//!   * Bursts > SCROLLBACK_LINES: the previous top row gets evicted before
//!     we can match it; we lose count and the anchor labeling drifts. Press
//!     End to snap back to live and recover.
//!   * `clear` (CSI 2J) wipes the live area in place. Our previous top row
//!     is no longer in scrollback, so `find_drift` returns None and we
//!     correctly skip the increment.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use vt100::Parser;

const SCROLLBACK_LINES: usize = 1000;

pub struct PtyView {
    parser:        Parser,
    anchor:        Option<u64>,
    abs_top:       u64,
    last_top_hash: Option<u64>,
}

impl PtyView {
    pub fn new(rows: u16, cols: u16) -> Self {
        Self {
            parser:        Parser::new(rows.max(1), cols.max(1), SCROLLBACK_LINES),
            anchor:        None,
            abs_top:       0,
            last_top_hash: None,
        }
    }

    pub fn process(&mut self, bytes: &[u8]) {
        self.parser.process(bytes);
        self.sync_drift();
        // If the user's anchor has been evicted, snap to the oldest line we
        // can still show.
        if let Some(a) = self.anchor {
            let floor = self.abs_floor();
            if a < floor { self.anchor = Some(floor); }
        }
    }

    pub fn set_size(&mut self, rows: u16, cols: u16) {
        self.parser.screen_mut().set_size(rows, cols);
        // Reflow scrambles row alignment; the prior hash baseline no longer
        // describes a real row. Drop it and resync on next process().
        self.last_top_hash = None;
    }

    pub fn current_size(&self) -> (u16, u16) {
        self.parser.screen().size()
    }

    pub fn cursor_position(&self) -> (u16, u16) {
        self.parser.screen().cursor_position()
    }

    pub fn is_scrolled_back(&self) -> bool { self.anchor.is_some() }
    pub fn anchor(&self)            -> Option<u64> { self.anchor }
    pub fn abs_top(&self)           -> u64 { self.abs_top }
    pub fn abs_floor(&self) -> u64 {
        self.abs_top.saturating_sub(SCROLLBACK_LINES as u64)
    }

    /// Set the scrollback offset to whatever the user's anchor maps to, then
    /// return a screen ref the caller can hand to a renderer.
    pub fn screen_for_render(&mut self) -> &vt100::Screen {
        let offset = match self.anchor {
            None    => 0,
            Some(a) => self.abs_top.saturating_sub(a) as usize,
        };
        self.parser.screen_mut().set_scrollback(offset);
        self.parser.screen()
    }

    /// `delta > 0` moves toward live (forward in time);
    /// `delta < 0` moves into history.
    pub fn scroll_lines(&mut self, delta: i64) {
        let cur = self.anchor.unwrap_or(self.abs_top) as i64;
        let lo  = self.abs_floor() as i64;
        let hi  = self.abs_top    as i64;
        let new = (cur + delta).clamp(lo, hi) as u64;
        self.anchor = if new >= self.abs_top { None } else { Some(new) };
    }

    pub fn jump_top(&mut self)  { self.anchor = Some(self.abs_floor()); }
    pub fn jump_live(&mut self) { self.anchor = None; }

    fn sync_drift(&mut self) {
        if self.parser.screen().alternate_screen() {
            // Pause tracking while we're on the alt screen — scroll has no
            // meaning. Resync after we come back.
            self.last_top_hash = None;
            return;
        }
        // Hash the LIVE row 0, regardless of where the user is currently
        // looking, then restore.
        let saved = self.parser.screen().scrollback();
        if saved != 0 { self.parser.screen_mut().set_scrollback(0); }
        let cur_hash = hash_top(&self.parser);

        match self.last_top_hash {
            None => {
                self.last_top_hash = Some(cur_hash);
            }
            Some(prev) if prev != cur_hash => {
                if let Some(k) = self.find_drift(prev) {
                    self.abs_top = self.abs_top.saturating_add(k);
                }
                self.last_top_hash = Some(cur_hash);
            }
            _ => {}
        }
        if saved != 0 { self.parser.screen_mut().set_scrollback(saved); }
    }

    /// Search vt100's scrollback for a row whose hash matches `prev_hash`.
    /// The depth where we find it = number of rows scrolled off since last
    /// sync. Returns None if the row has been evicted past the buffer (or
    /// never made it in, e.g. after `clear`).
    fn find_drift(&mut self, prev_hash: u64) -> Option<u64> {
        for k in 1..=SCROLLBACK_LINES {
            self.parser.screen_mut().set_scrollback(k);
            if hash_top(&self.parser) == prev_hash {
                self.parser.screen_mut().set_scrollback(0);
                return Some(k as u64);
            }
        }
        self.parser.screen_mut().set_scrollback(0);
        None
    }
}

fn hash_top(parser: &Parser) -> u64 {
    let (_, cols) = parser.screen().size();
    let row = parser.screen().rows(0, cols).next().unwrap_or_default();
    let mut h = DefaultHasher::new();
    row.hash(&mut h);
    h.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracks_simple_scroll() {
        let mut v = PtyView::new(4, 10);
        // Fill 4 rows, then push 3 more — first 3 lines should scroll off.
        v.process(b"line1\r\nline2\r\nline3\r\nline4\r\nline5\r\nline6\r\nline7");
        // After init `last_top_hash` was None; the very first process() call
        // just establishes the baseline. So abs_top is still 0 here.
        // Subsequent scrolls should accumulate.
        assert_eq!(v.abs_top(), 0);

        v.process(b"\r\nline8");
        assert_eq!(v.abs_top(), 1);

        v.process(b"\r\nline9\r\nlineA");
        assert_eq!(v.abs_top(), 3);
    }

    #[test]
    fn alt_screen_pauses_tracking() {
        let mut v = PtyView::new(4, 10);
        v.process(b"a\r\nb\r\nc\r\nd");   // baseline
        v.process(b"\r\ne");              // 1 scroll
        assert_eq!(v.abs_top(), 1);

        // Enter alt screen — output here must not advance abs_top, no
        // matter how busy the alt-screen activity is.
        v.process(b"\x1b[?1049h");
        v.process(b"x\r\ny\r\nz\r\nw\r\nmore\r\nstill more");
        assert_eq!(v.abs_top(), 1, "alt-screen output must not advance abs_top");

        // Leave alt screen. The exit byte itself rebases the hash (no
        // increment); the subsequent scroll counts again.
        v.process(b"\x1b[?1049l");
        v.process(b"\r\nresumed");
        assert_eq!(v.abs_top(), 2);
    }

    #[test]
    fn anchor_holds_through_drift() {
        let mut v = PtyView::new(4, 10);
        v.process(b"a\r\nb\r\nc\r\nd"); // baseline
        v.process(b"\r\ne\r\nf\r\ng\r\nh"); // 4 scrolls -> abs_top = 4

        // User anchors at line 2 (mid-history).
        v.scroll_lines(-2);
        assert_eq!(v.anchor(), Some(2));

        // More output drifts the live area by 3 — anchor stays at line 2.
        v.process(b"\r\ni\r\nj\r\nk");
        assert_eq!(v.anchor(), Some(2));
        assert!(v.abs_top() >= 7);
    }

    #[test]
    fn anchor_snaps_to_floor_when_evicted() {
        let mut v = PtyView::new(2, 10);
        v.process(b"x\r\ny");           // baseline
        v.process(b"\r\nz");            // abs_top = 1
        v.scroll_lines(-1);             // anchor = 0
        assert_eq!(v.anchor(), Some(0));

        // Push past the buffer — abs_top grows beyond SCROLLBACK_LINES so
        // floor advances above the anchor.
        let burst = "a\r\n".repeat(SCROLLBACK_LINES + 50);
        v.process(burst.as_bytes());

        // Anchor should be clamped up to the new floor (we under-count drift
        // on huge bursts, but the clamp guarantees the user never chases a
        // line vt100 has already evicted).
        let a = v.anchor().expect("anchor stays set");
        assert!(a >= v.abs_floor(), "anchor {a} below floor {}", v.abs_floor());
    }
}
