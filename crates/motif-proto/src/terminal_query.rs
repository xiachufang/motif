//! Streaming detector for terminal capability queries that shells (notably
//! fish) and prompt frameworks (starship, oh-my-posh) emit on stdout.
//!
//! Motif's PTY layer relays bytes through `pty.output` events. The shell
//! expects "the terminal" to answer queries like DA1 / OSC 11 / CPR by
//! writing response bytes back to its stdin — but in our split topology
//! there is no monolithic terminal at the shell's stdin: the client
//! emulators (vt100 in TUI, xterm.js in web) are downstream of a network
//! hop and may answer late or not at all. Late answers leak into the
//! shell's line editor as fake keystrokes (the user sees `^[]11;…` typed
//! into their prompt).
//!
//! This scanner makes the response path explicit:
//!   * the server runs it over each PTY chunk and *strips* recognized
//!     queries from the broadcast stream (so xterm.js never sees them and
//!     can't generate a delayed response);
//!   * any client that wants to answer feeds the same scanner over its
//!     incoming bytes and writes the canonical response via `pty.write`.
//!
//! The scanner is byte-streaming: queries split across read boundaries are
//! reassembled in `pending`, and bytes that turn out to NOT be a query
//! (an unrecognized CSI/OSC, garbage after ESC) are released into
//! `passthrough` in their original form so the downstream emulator sees
//! them unchanged.

// Headroom for the longest legitimately-buffered query. XTGETTCAP requests
// can chain multiple hex-encoded capability names with `;` separators, so
// 64 wasn't enough; 256 covers everything fish/starship emit in practice
// while still bounding how much we'd buffer for a genuinely-malformed
// escape that never terminates.
const MAX_PENDING: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueryKind {
    /// `ESC [ c` (or `ESC [ 0 c`) — Primary Device Attributes.
    Da1,
    /// `ESC [ > c` (or `ESC [ > 0 c`) — Secondary Device Attributes.
    Da2,
    /// `ESC [ 5 n` — Device Status Report (terminal OK?).
    Dsr5,
    /// `ESC [ 6 n` — Cursor Position Report query.
    Cpr,
    /// `ESC ] 10 ; ? ST` — Foreground colour query.
    Osc10,
    /// `ESC ] 11 ; ? ST` — Background colour query.
    Osc11,
    /// `ESC [ ? u` — Kitty Keyboard Protocol "what flags are set" query.
    /// fish 4.x sends this on startup; replying "no flags" tells it to
    /// skip Kitty-specific code paths instead of timing out.
    KittyKeyboard,
    /// `ESC [ > q` (or `ESC [ > 0 q`) — XTVERSION terminal name+version.
    /// fish 4.x's "terminal feature detection" leans on this.
    XtVersion,
    /// `ESC P + q <hex> ESC \` — XTGETTCAP termcap entry query. `hex_name`
    /// is the raw hex bytes the requester sent; the canonical "not
    /// recognized" reply echoes them back so the requester can correlate.
    XtGetTcap { hex_name: Vec<u8> },
}

impl QueryKind {
    /// Bytes the shell expects on its stdin in response. Values chosen to
    /// match what fish, starship, and oh-my-posh treat as a successful
    /// reply — any vaguely-conforming response unblocks them.
    pub fn canonical_response(&self) -> Vec<u8> {
        match self {
            // VT102 — minimal, accepted by every consumer we tested.
            Self::Da1   => b"\x1b[?6c".to_vec(),
            Self::Da2   => b"\x1b[>0;0;0c".to_vec(),
            Self::Dsr5  => b"\x1b[0n".to_vec(),
            // We don't track screen cursor position server-side; (1,1) is
            // a sentinel that callers (starship etc.) treat as "the
            // terminal answered, move on".
            Self::Cpr   => b"\x1b[1;1R".to_vec(),
            // Match the dark theme used by motif-web's xterm.js so prompt
            // frameworks pick a colour scheme consistent with the visible
            // background.
            Self::Osc10 => b"\x1b]10;rgb:e6e6/e6e6/e6e6\x1b\\".to_vec(),
            Self::Osc11 => b"\x1b]11;rgb:0a0a/0a0a/0a0a\x1b\\".to_vec(),
            // No Kitty keyboard protocol features enabled.
            Self::KittyKeyboard => b"\x1b[?0u".to_vec(),
            // XTVERSION reply: `DCS > | <name> ST`. The exact name doesn't
            // matter to fish — it just needs *some* answer to stop waiting.
            Self::XtVersion => b"\x1bP>|motif\x1b\\".to_vec(),
            // XTGETTCAP "not recognized": `DCS 0 + r <hex> ST`. (DCS 1 + r
            // would mean "found, here's the value"; we always say not
            // found so the client moves on rather than caching a guess.)
            Self::XtGetTcap { hex_name } => {
                let mut v = Vec::with_capacity(8 + hex_name.len());
                v.extend_from_slice(b"\x1bP0+r");
                v.extend_from_slice(hex_name);
                v.extend_from_slice(b"\x1b\\");
                v
            }
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ScanResult {
    /// Input bytes minus the recognized query sequences. Hand this to the
    /// downstream renderer / broadcast as if it were the raw PTY output.
    pub passthrough: Vec<u8>,
    /// Queries found in this batch, in arrival order. Each one's
    /// `canonical_response()` should be written back to the PTY stdin.
    pub queries:     Vec<QueryKind>,
}

#[derive(Default)]
pub struct QueryScanner {
    pending: Vec<u8>,
}

impl QueryScanner {
    pub fn new() -> Self { Self::default() }

    pub fn feed(&mut self, input: &[u8]) -> ScanResult {
        let mut r = ScanResult::default();
        for &b in input {
            self.step(b, &mut r);
        }
        r
    }

    fn step(&mut self, b: u8, r: &mut ScanResult) {
        if self.pending.is_empty() {
            if b == 0x1b { self.pending.push(b); }
            else         { r.passthrough.push(b); }
            return;
        }
        self.pending.push(b);

        if self.pending.len() > MAX_PENDING {
            // Pretender — release verbatim and reset. We may miss a query
            // here but the stream stays byte-accurate.
            r.passthrough.append(&mut self.pending);
            return;
        }

        // Need at least the introducer byte to decide CSI vs OSC vs other.
        if self.pending.len() < 2 { return; }

        let outcome = match self.pending[1] {
            b'[' => self.try_close_csi(),
            b']' => self.try_close_osc(),
            b'P' => self.try_close_dcs(),
            _    => Decision::Reject,
        };

        match outcome {
            Decision::Pending => {}
            Decision::Match(k) => {
                r.queries.push(k);
                self.pending.clear();
            }
            Decision::Reject => {
                r.passthrough.append(&mut self.pending);
            }
        }
    }

    fn try_close_csi(&self) -> Decision {
        if self.pending.len() < 3 { return Decision::Pending; }
        let last = *self.pending.last().unwrap();
        // CSI final byte is in 0x40..=0x7e. Earlier bytes are private-mode
        // markers (`?`, `>`, `=`) or parameter bytes (digits, `;`).
        if !(0x40..=0x7e).contains(&last) {
            return Decision::Pending;
        }
        // Body is everything between '[' and the final byte. Recognize the
        // canonical form (no params) AND the explicit-Ps form: `CSI Ps c`
        // is DA1 whether Ps is empty or "0", and fish 4.x emits the "0"
        // variant on startup.
        let body = &self.pending[2..self.pending.len() - 1];
        match (body, last) {
            (b"" | b"0", b'c')              => Decision::Match(QueryKind::Da1),
            (b">" | b">0", b'c')            => Decision::Match(QueryKind::Da2),
            (b"5", b'n')                    => Decision::Match(QueryKind::Dsr5),
            (b"6", b'n')                    => Decision::Match(QueryKind::Cpr),
            // Kitty Keyboard Protocol: `CSI ? u` — fish 4.x emits this.
            (b"?", b'u')                    => Decision::Match(QueryKind::KittyKeyboard),
            // XTVERSION query: `CSI > q` / `CSI > 0 q`. Note this collides
            // visually with the (much rarer) DECSCUSR `CSI Ps q` set form,
            // but DECSCUSR uses Ps without the `>` prefix, so the prefix
            // disambiguates.
            (b">" | b">0", b'q')            => Decision::Match(QueryKind::XtVersion),
            _                                => Decision::Reject,
        }
    }

    /// XTGETTCAP request comes in as `ESC P + q <hex> ESC \\`. We don't
    /// attempt to actually answer any termcap entry — just acknowledging
    /// "not recognized" with the canonical `DCS 0 + r <hex> ST` reply
    /// stops the requester from blocking on it.
    fn try_close_dcs(&self) -> Decision {
        let p = &self.pending;
        if p.len() < 4 { return Decision::Pending; }
        let last = *p.last().unwrap();
        // DCS terminator: ST (`ESC \\`) is canonical; some emitters use BEL.
        let bel_term = last == 0x07;
        let st_term  = p.len() >= 5 && p[p.len() - 2] == 0x1b && last == b'\\';
        if !bel_term && !st_term { return Decision::Pending; }

        let end = if st_term { p.len() - 2 } else { p.len() - 1 };
        // XTGETTCAP signature: `+q` immediately after the `ESC P` introducer.
        if p.len() >= 5 && p[2] == b'+' && p[3] == b'q' {
            let hex = p[4..end].to_vec();
            return Decision::Match(QueryKind::XtGetTcap { hex_name: hex });
        }
        Decision::Reject
    }

    fn try_close_osc(&self) -> Decision {
        let p = &self.pending;
        if p.len() < 3 { return Decision::Pending; }
        let last = *p.last().unwrap();
        // OSC ends at BEL (0x07) or ST (ESC \\).
        let bel_term = last == 0x07;
        let st_term  = p.len() >= 4 && p[p.len() - 2] == 0x1b && last == b'\\';
        if !bel_term && !st_term { return Decision::Pending; }

        let end = if st_term { p.len() - 2 } else { p.len() - 1 };
        match &p[2..end] {
            b"10;?" => Decision::Match(QueryKind::Osc10),
            b"11;?" => Decision::Match(QueryKind::Osc11),
            _       => Decision::Reject,
        }
    }
}

enum Decision {
    Pending,
    Match(QueryKind),
    Reject,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan_one(input: &[u8]) -> ScanResult {
        QueryScanner::new().feed(input)
    }

    #[test]
    fn passes_plain_text_unchanged() {
        let r = scan_one(b"hello world");
        assert_eq!(r.passthrough, b"hello world");
        assert!(r.queries.is_empty());
    }

    #[test]
    fn recognizes_da1_alone() {
        let r = scan_one(b"\x1b[c");
        assert!(r.passthrough.is_empty());
        assert_eq!(r.queries, vec![QueryKind::Da1]);
    }

    #[test]
    fn recognizes_each_csi_query() {
        for (bytes, kind) in [
            (&b"\x1b[c"[..],   QueryKind::Da1),
            // fish 4.x and other modern shells emit `Ps=0` explicitly.
            (&b"\x1b[0c"[..],  QueryKind::Da1),
            (&b"\x1b[>c"[..],  QueryKind::Da2),
            (&b"\x1b[>0c"[..], QueryKind::Da2),
            (&b"\x1b[5n"[..],  QueryKind::Dsr5),
            (&b"\x1b[6n"[..],  QueryKind::Cpr),
        ] {
            let r = scan_one(bytes);
            assert!(r.passthrough.is_empty(), "{:?}", bytes);
            assert_eq!(r.queries, vec![kind]);
        }
    }

    #[test]
    fn recognizes_osc11_query_both_terminators() {
        let r1 = scan_one(b"\x1b]11;?\x07");
        assert_eq!(r1.queries, vec![QueryKind::Osc11]);
        assert!(r1.passthrough.is_empty());

        let r2 = scan_one(b"\x1b]11;?\x1b\\");
        assert_eq!(r2.queries, vec![QueryKind::Osc11]);
        assert!(r2.passthrough.is_empty());
    }

    #[test]
    fn osc11_set_is_not_a_query() {
        // SET background, not a query — must pass through.
        let payload = b"\x1b]11;rgb:1234/5678/9abc\x07";
        let r = scan_one(payload);
        assert_eq!(r.passthrough, payload);
        assert!(r.queries.is_empty());
    }

    #[test]
    fn unrecognized_csi_passes_through() {
        // CUP — vt100 cursor movement, must not be eaten.
        let r = scan_one(b"\x1b[1;1H");
        assert_eq!(r.passthrough, b"\x1b[1;1H");
        assert!(r.queries.is_empty());
    }

    #[test]
    fn esc_followed_by_unrelated_byte_passes_through() {
        // ESC O — SS3 introducer; not our concern, must surface verbatim.
        let r = scan_one(b"\x1bOA");
        assert_eq!(r.passthrough, b"\x1bOA");
        assert!(r.queries.is_empty());
    }

    #[test]
    fn query_in_middle_of_text_extracts_only_query() {
        let r = scan_one(b"hello\x1b[cworld");
        assert_eq!(r.passthrough, b"helloworld");
        assert_eq!(r.queries, vec![QueryKind::Da1]);
    }

    #[test]
    fn multiple_queries_in_one_chunk() {
        let r = scan_one(b"\x1b[c\x1b]11;?\x07\x1b[6n");
        assert!(r.passthrough.is_empty());
        assert_eq!(r.queries, vec![QueryKind::Da1, QueryKind::Osc11, QueryKind::Cpr]);
    }

    #[test]
    fn split_query_across_two_feeds() {
        let mut s = QueryScanner::new();
        let a = s.feed(b"abc\x1b[");
        assert_eq!(a.passthrough, b"abc");
        assert!(a.queries.is_empty());

        let b = s.feed(b"cdef");
        assert_eq!(b.passthrough, b"def");
        assert_eq!(b.queries, vec![QueryKind::Da1]);
    }

    #[test]
    fn split_osc_across_three_feeds() {
        let mut s = QueryScanner::new();
        let a = s.feed(b"\x1b]");
        let b = s.feed(b"11;?");
        let c = s.feed(b"\x1b\\rest");
        assert!(a.passthrough.is_empty());
        assert!(b.passthrough.is_empty());
        assert_eq!(c.passthrough, b"rest");
        assert_eq!(a.queries.len() + b.queries.len(), 0);
        assert_eq!(c.queries, vec![QueryKind::Osc11]);
    }

    #[test]
    fn long_unrecognized_escape_overflows_to_passthrough() {
        // Long DCS-like sequence we don't recognize. The scanner should
        // give up after MAX_PENDING and let it through verbatim instead
        // of holding it forever.
        let mut input = Vec::from(&b"\x1bP"[..]);
        input.extend(std::iter::repeat(b'x').take(80));
        input.extend_from_slice(b"\x1b\\after");
        let r = scan_one(&input);
        assert!(r.queries.is_empty());
        // Every byte must reach passthrough — order preserved.
        assert_eq!(r.passthrough, input);
    }

    #[test]
    fn osc11_response_is_well_formed() {
        let bytes = QueryKind::Osc11.canonical_response();
        assert!(bytes.starts_with(b"\x1b]11;rgb:"));
        assert!(bytes.ends_with(b"\x1b\\"));
    }

    #[test]
    fn recognizes_kitty_keyboard_query() {
        let r = scan_one(b"\x1b[?u");
        assert!(r.passthrough.is_empty());
        assert_eq!(r.queries, vec![QueryKind::KittyKeyboard]);
    }

    #[test]
    fn recognizes_xtversion_query() {
        for bytes in [&b"\x1b[>q"[..], &b"\x1b[>0q"[..]] {
            let r = scan_one(bytes);
            assert!(r.passthrough.is_empty(), "{:?}", bytes);
            assert_eq!(r.queries, vec![QueryKind::XtVersion]);
        }
    }

    #[test]
    fn recognizes_xtgettcap_query_st_terminated() {
        // hex `696e646e` = ascii "indn" — what fish 4.x asks for first.
        let r = scan_one(b"\x1bP+q696e646e\x1b\\");
        assert!(r.passthrough.is_empty());
        match &r.queries[..] {
            [QueryKind::XtGetTcap { hex_name }] => {
                assert_eq!(hex_name.as_slice(), b"696e646e");
            }
            _ => panic!("expected XtGetTcap, got {:?}", r.queries),
        }
    }

    #[test]
    fn xtgettcap_canonical_echoes_hex_back() {
        // The "not recognized" reply must echo the same hex bytes the
        // requester sent so they can correlate the answer to their query.
        let q = QueryKind::XtGetTcap { hex_name: b"abc123".to_vec() };
        assert_eq!(q.canonical_response(), b"\x1bP0+rabc123\x1b\\");
    }

    #[test]
    fn xtversion_canonical_is_dcs_framed() {
        let bytes = QueryKind::XtVersion.canonical_response();
        assert!(bytes.starts_with(b"\x1bP>|"));
        assert!(bytes.ends_with(b"\x1b\\"));
    }

    #[test]
    fn fish_4x_startup_burst_strips_all_queries() {
        // Real bytes captured from fish 4.6 attaching to a motif PTY.
        // Every query in here must be recognized (no leak to passthrough)
        // except the actual mode-set / OSC-set sequences which are not
        // queries and must surface verbatim.
        let burst = b"\x1b[?u\
                      \x1b[>0q\
                      \x1b[?1049h\
                      \x1bP+q696e646e\x1b\\\
                      \x1bP+q71756572792d6f732d6e616d65\x1b\\\
                      \x1b[?1049l\
                      \x1b[0c";
        let r = scan_one(burst);
        // Five recognised queries: KittyKeyboard, XtVersion, two XTGETTCAPs,
        // and the trailing DA1.
        assert_eq!(r.queries.len(), 5, "queries: {:?}", r.queries);
        assert!(matches!(r.queries[0], QueryKind::KittyKeyboard));
        assert!(matches!(r.queries[1], QueryKind::XtVersion));
        assert!(matches!(r.queries[2], QueryKind::XtGetTcap { .. }));
        assert!(matches!(r.queries[3], QueryKind::XtGetTcap { .. }));
        assert!(matches!(r.queries[4], QueryKind::Da1));
        // The two `\x1b[?1049h/l` (alt-screen toggle) are mode SET ops,
        // not queries — they MUST stay in passthrough.
        let s = String::from_utf8_lossy(&r.passthrough);
        assert!(s.contains("\x1b[?1049h"), "alt-screen-enter dropped: {:?}", r.passthrough);
        assert!(s.contains("\x1b[?1049l"), "alt-screen-leave dropped: {:?}", r.passthrough);
    }
}
