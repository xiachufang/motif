//! Best-effort detection of the controlling terminal's foreground/background
//! colour. Used to seed `session.attach` so OSC 10/11 queries from the shell
//! (starship, oh-my-posh, …) get answered with the user's actual terminal
//! colours rather than a server-side hardcoded default.
//!
//! Strategy:
//!   1. OSC 10/11 query against the controlling tty (precise, RGB).
//!   2. `COLORFGBG` env var (xterm/rxvt convention; coarse — only a 16-colour
//!      index, but tells theme-aware prompts whether the background is light
//!      or dark, which is what most of them actually use it for).
//!
//! Returns `(fg, bg)` as the rgb portion of an OSC reply
//! (e.g. `"e6e6/e6e6/e6e6"`); either side may be `None` if detection failed.

pub fn probe() -> (Option<String>, Option<String>) {
    let (fg_osc, bg_osc) = osc_probe();
    if fg_osc.is_some() && bg_osc.is_some() { return (fg_osc, bg_osc); }
    let (fg_env, bg_env) = from_colorfgbg();
    (fg_osc.or(fg_env), bg_osc.or(bg_env))
}

#[cfg(unix)]
fn osc_probe() -> (Option<String>, Option<String>) {
    use std::io::{Read, Write};
    use std::os::unix::io::AsRawFd;
    use std::time::{Duration, Instant};

    // Both stdin and stdout must be a tty: stdin so the terminal can deliver
    // the response, stdout so writing the query bytes doesn't leak into a
    // redirected file.
    let stdin_fd  = std::io::stdin().as_raw_fd();
    let stdout_fd = std::io::stdout().as_raw_fd();
    if !is_tty(stdin_fd) || !is_tty(stdout_fd) {
        return (None, None);
    }

    let original = match get_termios(stdin_fd) {
        Some(t) => t,
        None    => return (None, None),
    };
    if !apply_raw_with_timeout(stdin_fd, &original) {
        return (None, None);
    }

    let mut stdout = std::io::stdout();
    let wrote = stdout.write_all(b"\x1b]10;?\x07\x1b]11;?\x07").is_ok()
        && stdout.flush().is_ok();

    let collected = if wrote {
        let mut buf = [0u8; 256];
        let mut out = Vec::new();
        let mut stdin = std::io::stdin();
        let deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < deadline {
            match stdin.read(&mut buf) {
                // VTIME elapsed with no bytes — try again until total deadline.
                Ok(0)  => {
                    if !out.is_empty() { break; }
                }
                Ok(n)  => {
                    out.extend_from_slice(&buf[..n]);
                    // Two responses arrive as two ESC-introduced sequences;
                    // stop early if we've plausibly seen both.
                    let escs = out.iter().filter(|b| **b == 0x1b).count();
                    let term = out.iter().filter(|b| **b == 0x07 || **b == b'\\').count();
                    if escs >= 2 && term >= 2 { break; }
                }
                Err(_) => break,
            }
        }
        out
    } else {
        Vec::new()
    };

    set_termios(stdin_fd, &original);
    parse_osc_responses(&collected)
}

#[cfg(not(unix))]
fn osc_probe() -> (Option<String>, Option<String>) { (None, None) }

#[cfg(unix)]
fn is_tty(fd: libc::c_int) -> bool {
    unsafe { libc::isatty(fd) == 1 }
}

#[cfg(unix)]
fn get_termios(fd: libc::c_int) -> Option<libc::termios> {
    let mut t: libc::termios = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(fd, &mut t) } != 0 { return None; }
    Some(t)
}

#[cfg(unix)]
fn set_termios(fd: libc::c_int, t: &libc::termios) {
    unsafe { libc::tcsetattr(fd, libc::TCSANOW, t) };
}

/// Switch stdin to a polling-style raw mode: no canonical line buffering, no
/// echo, and `read` returns after up to 200ms even with zero bytes (VMIN=0,
/// VTIME=2). The caller is responsible for restoring the original termios.
#[cfg(unix)]
fn apply_raw_with_timeout(fd: libc::c_int, original: &libc::termios) -> bool {
    let mut t = *original;
    t.c_lflag &= !(libc::ICANON | libc::ECHO | libc::ISIG | libc::IEXTEN);
    t.c_iflag &= !(libc::IXON | libc::ICRNL);
    t.c_cc[libc::VMIN]  = 0;
    t.c_cc[libc::VTIME] = 2;
    unsafe { libc::tcsetattr(fd, libc::TCSANOW, &t) == 0 }
}

fn parse_osc_responses(bytes: &[u8]) -> (Option<String>, Option<String>) {
    let s = String::from_utf8_lossy(bytes);
    (extract_rgb(&s, "10"), extract_rgb(&s, "11"))
}

fn extract_rgb(text: &str, tag: &str) -> Option<String> {
    // Looking for: ESC ] <tag> ; rgb: <body> ( BEL | ESC \ )
    let needle = format!("\x1b]{};rgb:", tag);
    let i = text.find(&needle)?;
    let rest = &text[i + needle.len()..];
    let end  = rest.find(|c: char| c == '\x07' || c == '\x1b')?;
    let rgb  = rest[..end].trim();
    if rgb.is_empty() { None } else { Some(rgb.to_string()) }
}

/// Parse the xterm/rxvt `COLORFGBG` env var, e.g. `"15;0"` (white-on-black)
/// or `"15;default;0"`. Maps the indices through the standard 16-colour
/// palette to a coarse RGB triple — enough for "is the background light or
/// dark" decisions in prompt themes.
fn from_colorfgbg() -> (Option<String>, Option<String>) {
    parse_colorfgbg(std::env::var("COLORFGBG").ok().as_deref())
}

fn parse_colorfgbg(v: Option<&str>) -> (Option<String>, Option<String>) {
    let Some(v) = v else { return (None, None) };
    let parts: Vec<&str> = v.split(';').collect();
    if parts.len() < 2 { return (None, None); }
    let fg = parts[0].parse::<u8>().ok().and_then(index_to_rgb);
    let bg = parts[parts.len() - 1].parse::<u8>().ok().and_then(index_to_rgb);
    (fg, bg)
}

fn index_to_rgb(i: u8) -> Option<String> {
    // Standard 16-colour palette (xterm defaults).
    let table: [(u8, u8, u8); 16] = [
        (0x00, 0x00, 0x00), (0xcd, 0x00, 0x00), (0x00, 0xcd, 0x00), (0xcd, 0xcd, 0x00),
        (0x00, 0x00, 0xee), (0xcd, 0x00, 0xcd), (0x00, 0xcd, 0xcd), (0xe5, 0xe5, 0xe5),
        (0x7f, 0x7f, 0x7f), (0xff, 0x00, 0x00), (0x00, 0xff, 0x00), (0xff, 0xff, 0x00),
        (0x5c, 0x5c, 0xff), (0xff, 0x00, 0xff), (0x00, 0xff, 0xff), (0xff, 0xff, 0xff),
    ];
    let (r, g, b) = *table.get(i as usize)?;
    // OSC 10/11 reply uses 16-bit components written as 4 hex digits each:
    // duplicating the 8-bit byte (e6 → e6e6) gives a value the same colour
    // observers expand to.
    Some(format!("{r:02x}{r:02x}/{g:02x}{g:02x}/{b:02x}{b:02x}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_osc11_response_st_terminator() {
        let bytes = b"\x1b]11;rgb:1e1e/1e1e/2020\x1b\\";
        assert_eq!(extract_rgb(&String::from_utf8_lossy(bytes), "11"),
                   Some("1e1e/1e1e/2020".into()));
    }

    #[test]
    fn parses_osc10_response_bel_terminator() {
        let bytes = b"\x1b]10;rgb:e6e6/e6e6/e6e6\x07garbage";
        assert_eq!(extract_rgb(&String::from_utf8_lossy(bytes), "10"),
                   Some("e6e6/e6e6/e6e6".into()));
    }

    #[test]
    fn parses_both_in_one_buffer() {
        let bytes = b"\x1b]10;rgb:f0f0/f0f0/f0f0\x07\x1b]11;rgb:0a0a/0a0a/0a0a\x1b\\";
        let (fg, bg) = parse_osc_responses(bytes);
        assert_eq!(fg.as_deref(), Some("f0f0/f0f0/f0f0"));
        assert_eq!(bg.as_deref(), Some("0a0a/0a0a/0a0a"));
    }

    #[test]
    fn missing_response_yields_none() {
        let (fg, bg) = parse_osc_responses(b"random bytes");
        assert!(fg.is_none() && bg.is_none());
    }

    #[test]
    fn colorfgbg_three_field_form() {
        // `15;default;0` — the middle "default" slot is what some emulators
        // emit when the second value isn't tracked separately.
        let (fg, bg) = parse_colorfgbg(Some("15;default;0"));
        assert!(fg.is_some());
        // bg index 0 = pure black.
        assert_eq!(bg.unwrap(), "0000/0000/0000");
    }

    #[test]
    fn colorfgbg_two_field_form() {
        let (fg, bg) = parse_colorfgbg(Some("0;15"));
        assert_eq!(fg.unwrap(), "0000/0000/0000");
        // bg index 15 = pure white.
        assert_eq!(bg.unwrap(), "ffff/ffff/ffff");
    }

    #[test]
    fn colorfgbg_absent_yields_none() {
        let (fg, bg) = parse_colorfgbg(None);
        assert!(fg.is_none() && bg.is_none());
    }
}
