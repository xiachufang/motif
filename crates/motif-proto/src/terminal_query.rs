//! Streaming detector for terminal control sequences that motifd needs to
//! intercept: capability queries (DA1 / OSC 11 / CPR / …) emitted by shells
//! and prompt frameworks, plus v2 shell-integration markers (OSC 133 / 7 /
//! 7770 / 7771) emitted by motif's bootstrap scripts.
//!
//! Two consumer patterns:
//!
//! * **Capability queries** (`canonical_response()` returns `Some(...)`):
//!   the shell expects "the terminal" to answer by writing response bytes
//!   back to its stdin. In motif's split topology there is no monolithic
//!   terminal at the shell's stdin — the client emulators (vt100 in TUI,
//!   xterm.js in web) are downstream of a network hop and may answer late
//!   or not at all. The server runs this scanner, *strips* the query from
//!   the broadcast stream, and writes the canonical response back to the
//!   PTY master immediately.
//!
//! * **Shell-integration markers** (`canonical_response()` returns `None`):
//!   motif's bootstrap script emits `OSC 133;A/B/C/D` (block boundaries),
//!   `OSC 7` (cwd), `OSC 7770;<hex>` (preexec command text), and
//!   `OSC 7771;<hex>` (precmd context JSON). The scanner consumes them and
//!   the server's `BlockState` state machine turns them into `Event::Pty*`
//!   broadcasts — they never reach client emulators.
//!
//! Anything not matched falls through `passthrough` byte-for-byte so
//! unrelated OSC / CSI / DCS sequences (alt-screen, OSC 9, OSC 1337, …)
//! reach the client emulators unchanged. The scanner is byte-streaming:
//! sequences split across read boundaries are reassembled in `pending`.

// Headroom for the longest legitimately-buffered query. XTGETTCAP requests
// can chain multiple hex-encoded capability names with `;` separators, so
// 64 wasn't enough; 256 covers everything fish/starship emit in practice
// while still bounding how much we'd buffer for a genuinely-malformed
// escape that never terminates.
const MAX_PENDING: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QueryKind {
    // ── Capability queries: server answers, strips, never broadcasts ──
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

    // ── Shell-integration markers: scanner consumes, no canonical answer.
    //    The server's BlockState turns these into Event::Pty* broadcasts. ──
    /// `ESC ] 7 ; file://<host>/<path> ST` — cwd update from precmd hook.
    /// The host segment is ignored; path is URL-decoded.
    Osc7Cwd { path: std::path::PathBuf },
    /// `ESC ] 133 ; A ST` — prompt about to render (FinalTerm A).
    Osc133PromptStart,
    /// `ESC ] 133 ; B ST` — prompt rendered, user input phase begins.
    Osc133PromptEnd,
    /// `ESC ] 133 ; C ST` — command starting to execute (preexec).
    Osc133CmdStart,
    /// `ESC ] 133 ; D [;<exit>] ST` — command finished, exit code is the
    /// `$?` shell observed on the *previous* command. `None` means the
    /// shell sent the terminator without a code (e.g., first prompt of a
    /// session).
    Osc133CmdEnd { exit: Option<i32> },
    /// `ESC ] 7770 ; <hex_command> ST` — preexec command text. The inner
    /// String is hex-decoded and lossily UTF-8-converted (binaries names
    /// or weird locales would otherwise reject the whole sequence).
    Osc7770Cmd { text: String },
    /// `ESC ] 7771 ; <hex_json> ST` — precmd context JSON. Successfully
    /// parsed into a typed `ShellContext`; if the inner JSON is malformed,
    /// the scanner drops the whole sequence to passthrough rather than
    /// surfacing a half-typed structure.
    Osc7771Context { ctx: crate::pty::ShellContext },
}

impl QueryKind {
    /// Bytes the shell expects on its stdin in response. `Some(...)` for
    /// capability queries (server should write back to the PTY master);
    /// `None` for shell-integration markers (no response — the BlockState
    /// state machine consumes them instead).
    pub fn canonical_response(&self) -> Option<Vec<u8>> {
        Some(match self {
            // VT102 — minimal, accepted by every consumer we tested.
            Self::Da1 => b"\x1b[?6c".to_vec(),
            Self::Da2 => b"\x1b[>0;0;0c".to_vec(),
            Self::Dsr5 => b"\x1b[0n".to_vec(),
            // We don't track screen cursor position server-side; (1,1) is
            // a sentinel that callers (starship etc.) treat as "the
            // terminal answered, move on".
            Self::Cpr => b"\x1b[1;1R".to_vec(),
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
            // Shell-integration markers: server consumes, no reply.
            Self::Osc7Cwd { .. }
            | Self::Osc133PromptStart
            | Self::Osc133PromptEnd
            | Self::Osc133CmdStart
            | Self::Osc133CmdEnd { .. }
            | Self::Osc7770Cmd { .. }
            | Self::Osc7771Context { .. } => return None,
        })
    }

    /// True if this is a v2 shell-integration marker (rather than a
    /// capability query). Convenience for `pty.rs` reader-loop routing.
    pub fn is_shell_integration(&self) -> bool {
        matches!(
            self,
            Self::Osc7Cwd { .. }
                | Self::Osc133PromptStart
                | Self::Osc133PromptEnd
                | Self::Osc133CmdStart
                | Self::Osc133CmdEnd { .. }
                | Self::Osc7770Cmd { .. }
                | Self::Osc7771Context { .. }
        )
    }
}

/// Decode an even-length ASCII hex string. Returns `None` on odd length or
/// any non-hex byte — caller should treat the whole OSC as malformed and
/// passthrough rather than mis-interpret a corrupted payload.
fn decode_hex(s: &[u8]) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    let nyb = |b: u8| -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        }
    };
    for chunk in s.chunks_exact(2) {
        out.push((nyb(chunk[0])? << 4) | nyb(chunk[1])?);
    }
    Some(out)
}

/// Decode a `file://[host]/path` URL into a PathBuf. Hex-encoded bytes
/// (`%20` etc.) are unescaped. Anything that doesn't start with `file://`
/// is taken as a literal path — a few shells emit just the path.
fn parse_file_uri(s: &[u8]) -> Option<std::path::PathBuf> {
    let bytes = if s.starts_with(b"file://") {
        // Skip past the host segment (between `//` and the first `/` of
        // the path). For `file:///abs` the host is empty.
        let after_scheme = &s[b"file://".len()..];
        let path_start = after_scheme.iter().position(|&b| b == b'/')?;
        &after_scheme[path_start..]
    } else {
        s
    };
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Some(decoded) = decode_hex(&bytes[i + 1..i + 3]) {
                out.push(decoded[0]);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    Some(std::path::PathBuf::from(String::from_utf8(out).ok()?))
}

/// One element of the time-ordered scan output. Use this when the
/// relative order of bytes and queries matters — for example, v2
/// shell-integration tags each `pty.output` chunk with the block_id
/// that was active *while those bytes flowed*, which only works if
/// queries and bytes interleave correctly inside a single chunk.
#[derive(Debug, Clone)]
pub enum ScanItem {
    /// A run of passthrough bytes (consecutive items are merged).
    Bytes(Vec<u8>),
    /// A recognized control sequence.
    Query(QueryKind),
}

#[derive(Debug, Clone, Default)]
pub struct ScanResult {
    /// All passthrough bytes from this batch, concatenated. Equivalent
    /// to `items.iter().filter_map(...).flatten().collect()`. Kept as a
    /// convenience for callers that don't care about interleaving order.
    pub passthrough: Vec<u8>,
    /// All queries found, in arrival order.
    pub queries: Vec<QueryKind>,
    /// Time-ordered passthrough chunks and queries. Reader loops that
    /// drive a state machine off the queries should walk this — the
    /// flat `passthrough` / `queries` are post-mixing and lose the
    /// "passthrough that arrived between query A and query B" timing.
    pub items: Vec<ScanItem>,
}

impl ScanResult {
    fn push_passthrough(&mut self, b: u8) {
        self.passthrough.push(b);
        match self.items.last_mut() {
            Some(ScanItem::Bytes(buf)) => buf.push(b),
            _ => self.items.push(ScanItem::Bytes(vec![b])),
        }
    }
    fn extend_passthrough(&mut self, bs: &[u8]) {
        self.passthrough.extend_from_slice(bs);
        match self.items.last_mut() {
            Some(ScanItem::Bytes(buf)) => buf.extend_from_slice(bs),
            _ => self.items.push(ScanItem::Bytes(bs.to_vec())),
        }
    }
    fn push_query(&mut self, q: QueryKind) {
        self.queries.push(q.clone());
        self.items.push(ScanItem::Query(q));
    }
}

#[derive(Default)]
pub struct QueryScanner {
    pending: Vec<u8>,
}

impl QueryScanner {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn feed(&mut self, input: &[u8]) -> ScanResult {
        let mut r = ScanResult::default();
        for &b in input {
            self.step(b, &mut r);
        }
        r
    }

    fn step(&mut self, b: u8, r: &mut ScanResult) {
        if self.pending.is_empty() {
            if b == 0x1b {
                self.pending.push(b);
            } else {
                r.push_passthrough(b);
            }
            return;
        }
        self.pending.push(b);

        if self.pending.len() > MAX_PENDING {
            // Pretender — release verbatim and reset. We may miss a query
            // here but the stream stays byte-accurate.
            let drained = std::mem::take(&mut self.pending);
            r.extend_passthrough(&drained);
            return;
        }

        // Need at least the introducer byte to decide CSI vs OSC vs other.
        if self.pending.len() < 2 {
            return;
        }

        let outcome = match self.pending[1] {
            b'[' => self.try_close_csi(),
            b']' => self.try_close_osc(),
            b'P' => self.try_close_dcs(),
            _ => Decision::Reject,
        };

        match outcome {
            Decision::Pending => {}
            Decision::Match(k) => {
                r.push_query(k);
                self.pending.clear();
            }
            Decision::Reject => {
                let drained = std::mem::take(&mut self.pending);
                r.extend_passthrough(&drained);
            }
        }
    }

    fn try_close_csi(&self) -> Decision {
        if self.pending.len() < 3 {
            return Decision::Pending;
        }
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
            (b"" | b"0", b'c') => Decision::Match(QueryKind::Da1),
            (b">" | b">0", b'c') => Decision::Match(QueryKind::Da2),
            (b"5", b'n') => Decision::Match(QueryKind::Dsr5),
            (b"6", b'n') => Decision::Match(QueryKind::Cpr),
            // Kitty Keyboard Protocol: `CSI ? u` — fish 4.x emits this.
            (b"?", b'u') => Decision::Match(QueryKind::KittyKeyboard),
            // XTVERSION query: `CSI > q` / `CSI > 0 q`. Note this collides
            // visually with the (much rarer) DECSCUSR `CSI Ps q` set form,
            // but DECSCUSR uses Ps without the `>` prefix, so the prefix
            // disambiguates.
            (b">" | b">0", b'q') => Decision::Match(QueryKind::XtVersion),
            _ => Decision::Reject,
        }
    }

    /// XTGETTCAP request comes in as `ESC P + q <hex> ESC \\`. We don't
    /// attempt to actually answer any termcap entry — just acknowledging
    /// "not recognized" with the canonical `DCS 0 + r <hex> ST` reply
    /// stops the requester from blocking on it.
    fn try_close_dcs(&self) -> Decision {
        let p = &self.pending;
        if p.len() < 4 {
            return Decision::Pending;
        }
        let last = *p.last().unwrap();
        // DCS terminator: ST (`ESC \\`) is canonical; some emitters use BEL.
        let bel_term = last == 0x07;
        let st_term = p.len() >= 5 && p[p.len() - 2] == 0x1b && last == b'\\';
        if !bel_term && !st_term {
            return Decision::Pending;
        }

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
        if p.len() < 3 {
            return Decision::Pending;
        }
        let last = *p.last().unwrap();
        // OSC ends at BEL (0x07) or ST (ESC \\).
        let bel_term = last == 0x07;
        let st_term = p.len() >= 4 && p[p.len() - 2] == 0x1b && last == b'\\';
        if !bel_term && !st_term {
            return Decision::Pending;
        }

        let end = if st_term { p.len() - 2 } else { p.len() - 1 };
        let body = &p[2..end];
        match body {
            b"10;?" => return Decision::Match(QueryKind::Osc10),
            b"11;?" => return Decision::Match(QueryKind::Osc11),
            _ => {}
        }

        // ── v2 shell-integration markers ──

        // OSC 7 ; file://...  (cwd update)
        if let Some(rest) = body.strip_prefix(b"7;") {
            return match parse_file_uri(rest) {
                Some(path) => Decision::Match(QueryKind::Osc7Cwd { path }),
                None => Decision::Reject,
            };
        }

        // OSC 133 ; <sub>[;<params>...]
        //
        // Bare A/B/C/D and D;<exit> are the FinalTerm baseline. Real shells
        // also emit subcommands with extra `key=value` parameters:
        //   - fish 4.x:  133;A;click_events=1, 133;C;cmdline_url=<percent>
        //   - iTerm2:    133;A;aid=<n>,        133;D;<exit>;err=<msg>
        //
        // We don't currently consume those params, but the edge MUST be
        // recognized — otherwise the block state machine never advances
        // past the first cycle (every redraw becomes a no-op and 133;C
        // never fires CommandStarted, leaving prompt_html empty).
        if let Some(rest) = body.strip_prefix(b"133;") {
            return match rest {
                b"A" => Decision::Match(QueryKind::Osc133PromptStart),
                b"B" => Decision::Match(QueryKind::Osc133PromptEnd),
                b"C" => Decision::Match(QueryKind::Osc133CmdStart),
                b"D" => Decision::Match(QueryKind::Osc133CmdEnd { exit: None }),
                _ => {
                    // Subcommand with parameter list: `<sub>;<rest>`.
                    if rest.get(1) != Some(&b';') {
                        // `133;<unknown>` (e.g. 133;E, 133;P) — surface
                        // verbatim so future FinalTerm extensions aren't
                        // silently swallowed.
                        return Decision::Reject;
                    }
                    let after_sub = &rest[2..];
                    match rest.first() {
                        Some(b'A') => Decision::Match(QueryKind::Osc133PromptStart),
                        Some(b'B') => Decision::Match(QueryKind::Osc133PromptEnd),
                        Some(b'C') => Decision::Match(QueryKind::Osc133CmdStart),
                        Some(b'D') => {
                            // `D;<exit>[;<extras>]` — first field is the
                            // exit code; everything after is ignored.
                            let first_field: &[u8] = match after_sub
                                .iter()
                                .position(|&b| b == b';')
                            {
                                Some(i) => &after_sub[..i],
                                None    => after_sub,
                            };
                            let s = std::str::from_utf8(first_field)
                                .ok()
                                .map(str::trim)
                                .unwrap_or("");
                            // Empty `D;` is malformed but treated as
                            // "exit unknown" rather than rejecting.
                            let exit = if s.is_empty() { None } else { s.parse::<i32>().ok() };
                            Decision::Match(QueryKind::Osc133CmdEnd { exit })
                        }
                        _ => Decision::Reject,
                    }
                }
            };
        }

        // OSC 7770 ; <hex>  (preexec command text)
        if let Some(hex) = body.strip_prefix(b"7770;") {
            return match decode_hex(hex).and_then(|bs| String::from_utf8(bs).ok()) {
                Some(text) => Decision::Match(QueryKind::Osc7770Cmd { text }),
                None => Decision::Reject,
            };
        }

        // OSC 7771 ; <hex>  (precmd context JSON)
        if let Some(hex) = body.strip_prefix(b"7771;") {
            return match decode_hex(hex)
                .and_then(|bs| serde_json::from_slice::<crate::pty::ShellContext>(&bs).ok())
            {
                Some(ctx) => Decision::Match(QueryKind::Osc7771Context { ctx }),
                None => Decision::Reject,
            };
        }

        Decision::Reject
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
            (&b"\x1b[c"[..], QueryKind::Da1),
            // fish 4.x and other modern shells emit `Ps=0` explicitly.
            (&b"\x1b[0c"[..], QueryKind::Da1),
            (&b"\x1b[>c"[..], QueryKind::Da2),
            (&b"\x1b[>0c"[..], QueryKind::Da2),
            (&b"\x1b[5n"[..], QueryKind::Dsr5),
            (&b"\x1b[6n"[..], QueryKind::Cpr),
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
        assert_eq!(
            r.queries,
            vec![QueryKind::Da1, QueryKind::Osc11, QueryKind::Cpr]
        );
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
        let bytes = QueryKind::Osc11.canonical_response().unwrap();
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
        let q = QueryKind::XtGetTcap {
            hex_name: b"abc123".to_vec(),
        };
        assert_eq!(q.canonical_response().unwrap(), b"\x1bP0+rabc123\x1b\\");
    }

    #[test]
    fn xtversion_canonical_is_dcs_framed() {
        let bytes = QueryKind::XtVersion.canonical_response().unwrap();
        assert!(bytes.starts_with(b"\x1bP>|"));
        assert!(bytes.ends_with(b"\x1b\\"));
    }

    // ── v2 shell-integration markers ──

    #[test]
    fn osc133_prompt_and_cmd_markers() {
        for (bytes, kind) in [
            (&b"\x1b]133;A\x07"[..], QueryKind::Osc133PromptStart),
            (&b"\x1b]133;B\x07"[..], QueryKind::Osc133PromptEnd),
            (&b"\x1b]133;C\x07"[..], QueryKind::Osc133CmdStart),
            (
                &b"\x1b]133;D\x07"[..],
                QueryKind::Osc133CmdEnd { exit: None },
            ),
            (
                &b"\x1b]133;D;0\x07"[..],
                QueryKind::Osc133CmdEnd { exit: Some(0) },
            ),
            (
                &b"\x1b]133;D;130\x1b\\"[..],
                QueryKind::Osc133CmdEnd { exit: Some(130) },
            ),
            (
                &b"\x1b]133;D;\x07"[..],
                QueryKind::Osc133CmdEnd { exit: None },
            ),
        ] {
            let r = scan_one(bytes);
            assert!(
                r.passthrough.is_empty(),
                "leak in passthrough: {bytes:?} -> {:?}",
                r.passthrough
            );
            assert_eq!(r.queries, vec![kind], "{:?}", bytes);
        }
    }

    #[test]
    fn osc133_parameterized_markers_match_their_subcommand() {
        // Real shells append `;key=value` params to A/B/C/D. We don't
        // consume the params yet but the edge must still resolve to the
        // baseline subcommand — otherwise the block state machine stalls
        // (e.g. fish 4.x's 133;A;click_events=1 redraw cycle would never
        // recycle the block_id and 133;C;cmdline_url=… would never fire
        // CommandStarted).
        for (bytes, kind) in [
            (
                &b"\x1b]133;A;click_events=1\x07"[..],
                QueryKind::Osc133PromptStart,
            ),
            (
                &b"\x1b]133;A;click_events=1\x1b\\"[..],
                QueryKind::Osc133PromptStart,
            ),
            (
                &b"\x1b]133;B;aid=foo\x07"[..],
                QueryKind::Osc133PromptEnd,
            ),
            (
                &b"\x1b]133;C;cmdline_url=false\x07"[..],
                QueryKind::Osc133CmdStart,
            ),
            (
                &b"\x1b]133;D;0;err=ok\x07"[..],
                QueryKind::Osc133CmdEnd { exit: Some(0) },
            ),
            (
                &b"\x1b]133;D;130;trailing=stuff\x1b\\"[..],
                QueryKind::Osc133CmdEnd { exit: Some(130) },
            ),
        ] {
            let r = scan_one(bytes);
            assert!(r.passthrough.is_empty(), "leak: {:?}", bytes);
            assert_eq!(r.queries, vec![kind], "{:?}", bytes);
        }
    }

    #[test]
    fn osc133_unknown_subcommand_is_passthrough() {
        // 133;E is not in our recognized set — must surface verbatim so
        // future FinalTerm extensions don't get silently swallowed.
        let bytes = b"\x1b]133;E\x07";
        let r = scan_one(bytes);
        assert!(r.queries.is_empty());
        assert_eq!(r.passthrough, bytes);
    }

    #[test]
    fn osc7_cwd_with_host() {
        // Real shells emit `file://hostname/path`; we ignore the host.
        let r = scan_one(b"\x1b]7;file://laptop.local/home/me/repo\x07");
        assert!(r.passthrough.is_empty());
        match &r.queries[..] {
            [QueryKind::Osc7Cwd { path }] => assert_eq!(path.as_os_str(), "/home/me/repo"),
            other => panic!("expected Osc7Cwd, got {other:?}"),
        }
    }

    #[test]
    fn osc7_cwd_url_decodes_percent_escapes() {
        let r = scan_one(b"\x1b]7;file:///path/with%20space\x07");
        match &r.queries[..] {
            [QueryKind::Osc7Cwd { path }] => assert_eq!(path.as_os_str(), "/path/with space"),
            other => panic!("expected Osc7Cwd with decoded space, got {other:?}"),
        }
    }

    #[test]
    fn osc7770_hex_decodes_command_text() {
        // hex of "echo hi" = 6563686f206869
        let r = scan_one(b"\x1b]7770;6563686f206869\x07");
        match &r.queries[..] {
            [QueryKind::Osc7770Cmd { text }] => assert_eq!(text, "echo hi"),
            other => panic!("expected Osc7770Cmd, got {other:?}"),
        }
    }

    #[test]
    fn osc7770_odd_length_hex_is_passthrough() {
        // Odd hex length is malformed — better to surface the bytes than
        // make up a value.
        let bytes = b"\x1b]7770;abc\x07";
        let r = scan_one(bytes);
        assert!(r.queries.is_empty());
        assert_eq!(r.passthrough, bytes);
    }

    #[test]
    fn osc7771_hex_decodes_to_shell_context() {
        // hex of {"branch":"main","venv":"work"}
        let json = r#"{"branch":"main","venv":"work"}"#;
        let hex: String = json.bytes().map(|b| format!("{b:02x}")).collect();
        let mut bytes = b"\x1b]7771;".to_vec();
        bytes.extend_from_slice(hex.as_bytes());
        bytes.push(0x07);
        let r = scan_one(&bytes);
        match &r.queries[..] {
            [QueryKind::Osc7771Context { ctx }] => {
                assert_eq!(ctx.branch.as_deref(), Some("main"));
                assert_eq!(ctx.venv.as_deref(), Some("work"));
                assert!(ctx.head.is_none());
            }
            other => panic!("expected Osc7771Context, got {other:?}"),
        }
    }

    #[test]
    fn osc7771_invalid_json_is_passthrough() {
        // Hex valid, but the decoded bytes aren't JSON-parseable. The
        // scanner shouldn't surface a half-typed ShellContext — rejecting
        // gives the downstream renderer a chance to ignore the OSC.
        let hex = "6e6f742d6a736f6e"; // "not-json"
        let mut bytes = b"\x1b]7771;".to_vec();
        bytes.extend_from_slice(hex.as_bytes());
        bytes.push(0x07);
        let r = scan_one(&bytes);
        assert!(r.queries.is_empty());
        assert_eq!(r.passthrough, bytes);
    }

    #[test]
    fn shell_integration_markers_have_no_response() {
        // Spec invariant: shell-integration markers must NOT generate
        // capability-style responses (otherwise we'd be writing OSC echoes
        // back to the shell stdin and confusing readline).
        for kind in [
            QueryKind::Osc133PromptStart,
            QueryKind::Osc133PromptEnd,
            QueryKind::Osc133CmdStart,
            QueryKind::Osc133CmdEnd { exit: Some(0) },
            QueryKind::Osc7Cwd { path: "/x".into() },
            QueryKind::Osc7770Cmd { text: "x".into() },
            QueryKind::Osc7771Context {
                ctx: crate::pty::ShellContext::default(),
            },
        ] {
            assert!(
                kind.canonical_response().is_none(),
                "{:?} leaked a response",
                kind
            );
            assert!(
                kind.is_shell_integration(),
                "{:?} not flagged as shell-integration",
                kind
            );
        }
    }

    #[test]
    fn full_command_lifecycle_in_one_chunk() {
        // Realistic precmd → preexec → cmd → finish burst.
        // Hex of "ls -la" = 6c73202d6c61
        let burst = b"\x1b]133;D;0\x07\
                      \x1b]133;A\x07\
                      \x1b]7;file:///tmp\x07\
                      \x1b]133;B\x07\
                      \x1b]7770;6c73202d6c61\x07\
                      \x1b]133;C\x07";
        let r = scan_one(burst);
        assert!(
            r.passthrough.is_empty(),
            "passthrough leak: {:?}",
            r.passthrough
        );
        assert_eq!(r.queries.len(), 6);
        assert!(matches!(
            r.queries[0],
            QueryKind::Osc133CmdEnd { exit: Some(0) }
        ));
        assert!(matches!(r.queries[1], QueryKind::Osc133PromptStart));
        match &r.queries[2] {
            QueryKind::Osc7Cwd { path } => assert_eq!(path.as_os_str(), "/tmp"),
            other => panic!("expected Osc7Cwd, got {other:?}"),
        }
        assert!(matches!(r.queries[3], QueryKind::Osc133PromptEnd));
        match &r.queries[4] {
            QueryKind::Osc7770Cmd { text } => assert_eq!(text, "ls -la"),
            other => panic!("expected Osc7770Cmd, got {other:?}"),
        }
        assert!(matches!(r.queries[5], QueryKind::Osc133CmdStart));
    }

    #[test]
    fn osc133_split_across_three_feeds() {
        // Marker reassembly across read boundaries — same machinery used
        // for capability queries already covers this; sanity-check.
        let mut s = QueryScanner::new();
        let a = s.feed(b"output\x1b]");
        let b = s.feed(b"133;D;");
        let c = s.feed(b"42\x07more");
        assert_eq!(a.passthrough, b"output");
        assert!(b.passthrough.is_empty());
        assert_eq!(c.passthrough, b"more");
        assert_eq!(c.queries, vec![QueryKind::Osc133CmdEnd { exit: Some(42) }]);
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
        assert!(
            s.contains("\x1b[?1049h"),
            "alt-screen-enter dropped: {:?}",
            r.passthrough
        );
        assert!(
            s.contains("\x1b[?1049l"),
            "alt-screen-leave dropped: {:?}",
            r.passthrough
        );
    }
}
