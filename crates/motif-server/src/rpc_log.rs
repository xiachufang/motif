//! Helpers for the optional `--rpc-log` debug stream.
//!
//! All RPC frames (incoming requests, outgoing responses, outgoing
//! notifications) are emitted via `tracing::trace!(target: TARGET, …)`.
//! `init_tracing` in `lib.rs` wires a dedicated file layer for this
//! target so the noise stays out of stderr.

/// Custom tracing target. The init_tracing layered subscriber lets only
/// this target through to the rpc log file, and excludes it from
/// stderr so the operator's regular logs aren't drowned.
pub const TARGET: &str = "motif::rpc";

/// Soft cap on a single logged frame. PTY output / blob frames can
/// reach tens of KB of base64; truncating keeps the log readable while
/// still showing structure (method, ids, the head of params).
pub const MAX_LEN: usize = 2048;

/// Truncate a string for the log without slicing inside a UTF-8
/// boundary. Returns a Cow because most frames are small.
pub fn truncate(s: &str) -> std::borrow::Cow<'_, str> {
    if s.len() <= MAX_LEN {
        return std::borrow::Cow::Borrowed(s);
    }
    let mut end = MAX_LEN;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    std::borrow::Cow::Owned(format!("{}…[+{}B]", &s[..end], s.len() - end))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_short_borrows() {
        let s = "hi";
        let out = truncate(s);
        assert!(matches!(out, std::borrow::Cow::Borrowed(_)));
        assert_eq!(out, "hi");
    }

    #[test]
    fn truncate_long_marks_remaining_bytes() {
        let s = "x".repeat(MAX_LEN + 100);
        let out = truncate(&s);
        assert!(out.len() < s.len());
        assert!(out.contains("…[+100B]"));
    }

    #[test]
    fn truncate_does_not_slice_inside_a_codepoint() {
        // 4-byte char repeated; pick a length that lands mid-codepoint.
        let s = "🍣".repeat(MAX_LEN); // ≈ 4*MAX_LEN bytes
        let out = truncate(&s);
        // The truncation must still produce valid UTF-8.
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
    }
}
