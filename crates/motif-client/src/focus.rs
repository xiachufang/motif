//! Focus-reporting (DECSET 1004) management for the raw passthrough host
//! (`motif-cast`).
//!
//! `motif-cast` is a thin byte pipe between a real local terminal and a PTY
//! living inside motifd. To know when the user is actually *looking at* the
//! cast (so it can re-assert PTY primary), it enables focus reporting on the
//! local terminal itself and reads the `CSI I` / `CSI O` focus events. But the
//! inner program (vim, tmux, …) also manages 1004 for its own redraw/save
//! logic, and both parties' control sequences are multiplexed on the same two
//! byte streams. These two filters arbitrate that, the way a real multiplexer
//! would:
//!
//! * [`OutputFocusFilter`] scans the PTY→terminal stream and **strips** the
//!   inner program's `ESC[?1004h` / `ESC[?1004l`, recording whether the inner
//!   program wants focus events. The local terminal's 1004 state is owned
//!   solely by the host (kept on for the session), so the inner program can't
//!   turn it off underneath us.
//! * [`InputFocusFilter`] scans the terminal→PTY stream for `ESC[I` / `ESC[O`,
//!   surfacing them to the host (to reclaim primary) and forwarding them to
//!   the inner program **only when it enabled 1004** — otherwise a plain shell
//!   would receive spurious `^[[I` "input".
//!
//! Both are byte-streaming and carry partial matches across `feed` calls, so a
//! sequence split across two reads is handled correctly. Matching is on the
//! exact fixed byte strings (which programs never emit as data), so unrelated
//! escapes — `ESC[?1049h` (alt-screen), `ESC[A` (arrow), `ESCOP` (SS3 F1) —
//! pass through verbatim.

/// `ESC ] ` … no — the prefix shared by `ESC[?1004h` and `ESC[?1004l`. The
/// final byte (`h` enable / `l` disable) is matched separately.
const OUT_PREFIX: &[u8] = b"\x1b[?1004";

/// The CSI introducer shared by focus-in (`ESC[I`) and focus-out (`ESC[O`).
const IN_PREFIX: &[u8] = b"\x1b[";

/// Local-terminal control sequences to enable / disable focus reporting.
pub const ENABLE_FOCUS: &[u8] = b"\x1b[?1004h";
pub const DISABLE_FOCUS: &[u8] = b"\x1b[?1004l";

/// Strips the inner program's `ESC[?1004h` / `ESC[?1004l` from the PTY output
/// stream, reporting each toggle (`true` = enable, `false` = disable).
#[derive(Default)]
pub struct OutputFocusFilter {
    /// How many bytes of `OUT_PREFIX` (then +1 for the pending terminal) have
    /// matched so far and are being held back.
    matched: usize,
}

impl OutputFocusFilter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed a chunk. Cleaned bytes (everything except complete 1004 toggles)
    /// are appended to `out`; each toggle is appended to `toggles`.
    pub fn feed(&mut self, input: &[u8], out: &mut Vec<u8>, toggles: &mut Vec<bool>) {
        for &b in input {
            if self.matched == OUT_PREFIX.len() {
                // Prefix complete; expecting the terminal `h`/`l`.
                if b == b'h' || b == b'l' {
                    toggles.push(b == b'h');
                    self.matched = 0; // drop the whole sequence
                } else {
                    out.extend_from_slice(OUT_PREFIX);
                    self.matched = 0;
                    self.ground(b, out);
                }
                continue;
            }
            if b == OUT_PREFIX[self.matched] {
                self.matched += 1;
            } else {
                out.extend_from_slice(&OUT_PREFIX[..self.matched]);
                self.matched = 0;
                self.ground(b, out);
            }
        }
    }

    /// Re-examine a byte that broke a partial match. `OUT_PREFIX` contains ESC
    /// only at index 0, so a held prefix never hides an interior restart —
    /// re-checking just this byte is sufficient.
    fn ground(&mut self, b: u8, out: &mut Vec<u8>) {
        if b == OUT_PREFIX[0] {
            self.matched = 1;
        } else {
            out.push(b);
        }
    }

    /// Emit any held partial prefix (stream ended mid-sequence).
    pub fn flush(&mut self, out: &mut Vec<u8>) {
        if self.matched > 0 {
            out.extend_from_slice(&OUT_PREFIX[..self.matched.min(OUT_PREFIX.len())]);
            self.matched = 0;
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusEvent {
    In,
    Out,
}

/// Detects `ESC[I` / `ESC[O` in the terminal input stream. The host uses the
/// events to reclaim primary; the sequences themselves are forwarded to the
/// inner program only when it has enabled 1004 (`forward`), else stripped.
#[derive(Default)]
pub struct InputFocusFilter {
    matched: usize,
}

impl InputFocusFilter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed a chunk. `forward` keeps focus sequences in `out` (inner program
    /// wants them); otherwise they're stripped. Detected events are appended
    /// to `events`. All non-focus bytes pass through to `out` unchanged.
    pub fn feed(
        &mut self,
        input: &[u8],
        forward: bool,
        out: &mut Vec<u8>,
        events: &mut Vec<FocusEvent>,
    ) {
        for &b in input {
            if self.matched == IN_PREFIX.len() {
                // Got `ESC[`; expecting `I`/`O`.
                if b == b'I' || b == b'O' {
                    events.push(if b == b'I' {
                        FocusEvent::In
                    } else {
                        FocusEvent::Out
                    });
                    if forward {
                        out.extend_from_slice(IN_PREFIX);
                        out.push(b);
                    }
                    self.matched = 0;
                } else {
                    out.extend_from_slice(IN_PREFIX);
                    self.matched = 0;
                    self.ground(b, out);
                }
                continue;
            }
            if b == IN_PREFIX[self.matched] {
                self.matched += 1;
            } else {
                out.extend_from_slice(&IN_PREFIX[..self.matched]);
                self.matched = 0;
                self.ground(b, out);
            }
        }
    }

    fn ground(&mut self, b: u8, out: &mut Vec<u8>) {
        if b == IN_PREFIX[0] {
            self.matched = 1;
        } else {
            out.push(b);
        }
    }

    /// Emit any held partial prefix (stream ended mid-sequence).
    pub fn flush(&mut self, out: &mut Vec<u8>) {
        if self.matched > 0 {
            out.extend_from_slice(&IN_PREFIX[..self.matched.min(IN_PREFIX.len())]);
            self.matched = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn out_feed(chunks: &[&[u8]]) -> (Vec<u8>, Vec<bool>) {
        let mut f = OutputFocusFilter::new();
        let mut out = Vec::new();
        let mut toggles = Vec::new();
        for c in chunks {
            f.feed(c, &mut out, &mut toggles);
        }
        f.flush(&mut out);
        (out, toggles)
    }

    #[test]
    fn output_passes_plain_text() {
        let (out, t) = out_feed(&[b"hello world"]);
        assert_eq!(out, b"hello world");
        assert!(t.is_empty());
    }

    #[test]
    fn output_strips_enable_and_disable() {
        let (out, t) = out_feed(&[b"a\x1b[?1004hb\x1b[?1004lc"]);
        assert_eq!(out, b"abc");
        assert_eq!(t, vec![true, false]);
    }

    #[test]
    fn output_preserves_near_miss_sequences() {
        // alt-screen, cursor show, bracketed paste — all `ESC[?...h/l` but not 1004.
        let input = b"\x1b[?1049h\x1b[?25h\x1b[?2004h";
        let (out, t) = out_feed(&[input]);
        assert_eq!(out, input);
        assert!(t.is_empty());
    }

    #[test]
    fn output_handles_split_across_feeds() {
        let (out, t) = out_feed(&[b"x\x1b[?10", b"04h", b"y"]);
        assert_eq!(out, b"xy");
        assert_eq!(t, vec![true]);
    }

    #[test]
    fn output_flushes_incomplete_prefix() {
        // Stream ends mid-prefix → the partial bytes are real output.
        let (out, t) = out_feed(&[b"z\x1b[?100"]);
        assert_eq!(out, b"z\x1b[?100");
        assert!(t.is_empty());
    }

    #[test]
    fn output_double_esc_restarts_match() {
        let (out, t) = out_feed(&[b"\x1b\x1b[?1004h"]);
        assert_eq!(out, b"\x1b");
        assert_eq!(t, vec![true]);
    }

    fn in_feed(chunks: &[&[u8]], forward: bool) -> (Vec<u8>, Vec<FocusEvent>) {
        let mut f = InputFocusFilter::new();
        let mut out = Vec::new();
        let mut ev = Vec::new();
        for c in chunks {
            f.feed(c, forward, &mut out, &mut ev);
        }
        f.flush(&mut out);
        (out, ev)
    }

    #[test]
    fn input_strips_focus_when_inner_disabled() {
        let (out, ev) = in_feed(&[b"a\x1b[Ib\x1b[Oc"], false);
        assert_eq!(out, b"abc");
        assert_eq!(ev, vec![FocusEvent::In, FocusEvent::Out]);
    }

    #[test]
    fn input_forwards_focus_when_inner_enabled() {
        let (out, ev) = in_feed(&[b"\x1b[I"], true);
        assert_eq!(out, b"\x1b[I");
        assert_eq!(ev, vec![FocusEvent::In]);
    }

    #[test]
    fn input_preserves_arrow_keys() {
        let (out, ev) = in_feed(&[b"\x1b[A\x1b[B\x1b[1;2C"], false);
        assert_eq!(out, b"\x1b[A\x1b[B\x1b[1;2C");
        assert!(ev.is_empty());
    }

    #[test]
    fn input_preserves_ss3_keys() {
        // `ESC O P` (F1, SS3) must not be confused with focus-out `ESC [ O`.
        let (out, ev) = in_feed(&[b"\x1bOP"], false);
        assert_eq!(out, b"\x1bOP");
        assert!(ev.is_empty());
    }

    #[test]
    fn input_handles_split_across_feeds() {
        let (out, ev) = in_feed(&[b"\x1b", b"[", b"I"], false);
        assert!(out.is_empty());
        assert_eq!(ev, vec![FocusEvent::In]);
    }
}
