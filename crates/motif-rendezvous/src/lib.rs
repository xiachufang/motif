//! Rendezvous relay core.
//!
//! Both `motifd` (role [`ROLE_ACCEPT`]) and the client (role [`ROLE_CONNECT`])
//! dial out to the relay and send a fixed [`HELLO_LEN`]-byte HELLO frame
//! carrying a role and a 32-byte token. The relay pairs an `accept` with a
//! `connect` bearing the same token, writes [`CTRL_PAIRED`] to both, then
//! `copy_bidirectional`s them — a dumb pipe that only ever sees ciphertext.
//!
//! See `docs/rzv-protocol.md` for the shared wire contract; the Dart client
//! side lives in `apps/flutter/lib/motif/net/rzv/`.
//!
//! Security posture mirrors `motif-push-relay`: this process does not terminate
//! TLS — listen on loopback / a trusted segment and front it with a
//! TLS-terminating proxy. The token is a capability to *meet*, not auth;
//! confidentiality/authenticity belong to the layer above (P2: TLS pinned to
//! motifd's identity key).

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// 4-byte magic: ASCII "MRZV".
pub const MAGIC: [u8; 4] = *b"MRZV";
pub const VERSION: u8 = 1;

pub const ROLE_ACCEPT: u8 = 0;
pub const ROLE_CONNECT: u8 = 1;
/// A liveness probe. The relay replies with [`CTRL_HEALTH_OK`] and closes —
/// it is never parked or paired, so it leaves no state behind.
pub const ROLE_HEALTH: u8 = 2;

/// Sent to both sides at pairing; after it the stream is transparent.
pub const CTRL_PAIRED: u8 = 0x10;
/// Reply to a [`ROLE_HEALTH`] HELLO: the relay's event loop and HELLO parser
/// are alive. Distinct from [`CTRL_PAIRED`] so a probe can't be mistaken for a
/// real pairing.
pub const CTRL_HEALTH_OK: u8 = 0x20;

pub const TOKEN_LEN: usize = 32;
pub const HELLO_LEN: usize = 4 + 1 + 1 + TOKEN_LEN; // 38

pub type Token = [u8; TOKEN_LEN];

/// How long a HELLO is allowed to take before we drop the connection.
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);

struct Parked {
    stream: TcpStream,
    since: Instant,
}

#[derive(Default)]
struct Waiters {
    accepts: VecDeque<Parked>,
    connects: VecDeque<Parked>,
}

impl Waiters {
    fn is_empty(&self) -> bool {
        self.accepts.is_empty() && self.connects.is_empty()
    }
}

pub struct HubConfig {
    /// Drop a parked (unpaired) connection after it has waited this long.
    pub park_ttl: Duration,
}

impl Default for HubConfig {
    fn default() -> Self {
        Self {
            park_ttl: Duration::from_secs(300),
        }
    }
}

/// The relay's shared pairing state.
pub struct Hub {
    inner: Mutex<HashMap<Token, Waiters>>,
    park_ttl: Duration,
}

impl Hub {
    pub fn new(cfg: HubConfig) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(HashMap::new()),
            park_ttl: cfg.park_ttl,
        })
    }

    /// Accept connections forever, pairing them by token. Also spawns the
    /// TTL reaper. Returns only if the listener errors irrecoverably (it
    /// currently retries all accept errors, so this never returns in practice).
    pub async fn run(self: Arc<Self>, listener: TcpListener) {
        let reaper = Arc::clone(&self);
        tokio::spawn(async move { reaper.reap_loop().await });

        loop {
            match listener.accept().await {
                Ok((stream, peer)) => {
                    let hub = Arc::clone(&self);
                    tokio::spawn(async move {
                        if let Err(e) = hub.handle(stream).await {
                            tracing::debug!(%peer, error = %e, "rzv: connection ended");
                        }
                    });
                }
                Err(e) => {
                    tracing::warn!(error = %e, "rzv: accept failed; retrying");
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            }
        }
    }

    async fn handle(self: Arc<Self>, stream: TcpStream) -> anyhow::Result<()> {
        let mut stream = stream;
        let (role, token) = read_hello(&mut stream).await?;

        // A health probe is answered inline and dropped — never parked/paired.
        if role == ROLE_HEALTH {
            stream.write_all(&[CTRL_HEALTH_OK]).await?;
            stream.flush().await?;
            return Ok(());
        }

        // Pop an opposite-role waiter or park self — both under one lock so a
        // simultaneous accept+connect can't each miss the other and deadlock.
        let mut stream = Some(stream);
        let partner: Option<TcpStream> = {
            let mut map = self.inner.lock();
            let w = map.entry(token).or_default();
            let opposite = if role == ROLE_ACCEPT {
                w.connects.pop_front()
            } else {
                w.accepts.pop_front()
            };
            match opposite {
                Some(p) => {
                    if w.is_empty() {
                        map.remove(&token);
                    }
                    Some(p.stream)
                }
                None => {
                    let parked = Parked {
                        stream: stream.take().expect("stream present"),
                        since: Instant::now(),
                    };
                    if role == ROLE_ACCEPT {
                        w.accepts.push_back(parked);
                    } else {
                        w.connects.push_back(parked);
                    }
                    None
                }
            }
        };

        if let Some(partner) = partner {
            let me = stream.take().expect("stream present");
            splice(me, partner).await;
        }
        Ok(())
    }

    async fn reap_loop(self: Arc<Self>) {
        let mut tick = tokio::time::interval(Duration::from_secs(30));
        loop {
            tick.tick().await;
            let now = Instant::now();
            let ttl = self.park_ttl;
            let mut map = self.inner.lock();
            map.retain(|_tok, w| {
                w.accepts.retain(|p| now.duration_since(p.since) < ttl);
                w.connects.retain(|p| now.duration_since(p.since) < ttl);
                !w.is_empty()
            });
        }
    }

    /// Number of tokens with at least one parked connection. Test/diagnostic.
    pub fn parked_tokens(&self) -> usize {
        self.inner.lock().len()
    }
}

/// Read and validate the fixed HELLO frame; return the role and token.
async fn read_hello(stream: &mut TcpStream) -> anyhow::Result<(u8, Token)> {
    let mut buf = [0u8; HELLO_LEN];
    tokio::time::timeout(HELLO_TIMEOUT, stream.read_exact(&mut buf))
        .await
        .map_err(|_| anyhow::anyhow!("HELLO timed out"))??;
    if buf[0..4] != MAGIC {
        anyhow::bail!("bad magic");
    }
    if buf[4] != VERSION {
        anyhow::bail!("unsupported version {}", buf[4]);
    }
    let role = buf[5];
    if role != ROLE_ACCEPT && role != ROLE_CONNECT && role != ROLE_HEALTH {
        anyhow::bail!("bad role {role}");
    }
    let mut token = [0u8; TOKEN_LEN];
    token.copy_from_slice(&buf[6..6 + TOKEN_LEN]);
    Ok((role, token))
}

/// Client side of the health protocol: dial the relay, send a [`ROLE_HEALTH`]
/// HELLO, and confirm it replies [`CTRL_HEALTH_OK`]. Proves the listener is up
/// *and* the HELLO parser / response path run — more than a bare TCP connect,
/// and it parks no state. Used by the `healthcheck` subcommand and the image's
/// `HEALTHCHECK`. `timeout` bounds the whole exchange.
pub async fn health_check(addr: &str, timeout: Duration) -> anyhow::Result<()> {
    tokio::time::timeout(timeout, async {
        let mut stream = TcpStream::connect(addr).await?;
        let mut frame = [0u8; HELLO_LEN];
        frame[0..4].copy_from_slice(&MAGIC);
        frame[4] = VERSION;
        frame[5] = ROLE_HEALTH;
        // token bytes stay zero — unused for a health probe.
        stream.write_all(&frame).await?;
        stream.flush().await?;
        let mut b = [0u8; 1];
        stream.read_exact(&mut b).await?;
        if b[0] != CTRL_HEALTH_OK {
            anyhow::bail!("unexpected health reply {:#04x}", b[0]);
        }
        Ok(())
    })
    .await
    .map_err(|_| anyhow::anyhow!("health probe timed out after {timeout:?}"))?
}

/// Signal both sides, then pipe bytes until either closes.
async fn splice(mut a: TcpStream, mut b: TcpStream) {
    if let Err(e) = async {
        a.write_all(&[CTRL_PAIRED]).await?;
        b.write_all(&[CTRL_PAIRED]).await?;
        a.flush().await?;
        b.flush().await?;
        Ok::<_, std::io::Error>(())
    }
    .await
    {
        tracing::debug!(error = %e, "rzv: failed to signal PAIRED");
        return;
    }
    match tokio::io::copy_bidirectional(&mut a, &mut b).await {
        Ok((a2b, b2a)) => tracing::debug!(a2b, b2a, "rzv: splice closed"),
        Err(e) => tracing::debug!(error = %e, "rzv: splice ended"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn start_hub() -> std::net::SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let hub = Hub::new(HubConfig {
            park_ttl: Duration::from_millis(300),
        });
        tokio::spawn(hub.run(listener));
        addr
    }

    fn hello(role: u8, token: &Token) -> Vec<u8> {
        let mut v = Vec::with_capacity(HELLO_LEN);
        v.extend_from_slice(&MAGIC);
        v.push(VERSION);
        v.push(role);
        v.extend_from_slice(token);
        v
    }

    async fn read_byte(s: &mut TcpStream) -> u8 {
        let mut b = [0u8; 1];
        s.read_exact(&mut b).await.unwrap();
        b[0]
    }

    #[tokio::test]
    async fn pairs_and_pipes_both_directions() {
        let addr = start_hub().await;
        let token = [7u8; TOKEN_LEN];

        let mut acc = TcpStream::connect(addr).await.unwrap();
        acc.write_all(&hello(ROLE_ACCEPT, &token)).await.unwrap();

        let mut con = TcpStream::connect(addr).await.unwrap();
        con.write_all(&hello(ROLE_CONNECT, &token)).await.unwrap();

        // Both observe PAIRED.
        assert_eq!(read_byte(&mut acc).await, CTRL_PAIRED);
        assert_eq!(read_byte(&mut con).await, CTRL_PAIRED);

        // connect -> accept
        con.write_all(b"ping").await.unwrap();
        let mut buf = [0u8; 4];
        acc.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"ping");

        // accept -> connect
        acc.write_all(b"pong").await.unwrap();
        con.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"pong");
    }

    #[tokio::test]
    async fn does_not_pair_same_role_or_mismatched_token() {
        let addr = start_hub().await;

        // Two connects with the same token must NOT pair with each other.
        let token = [1u8; TOKEN_LEN];
        let mut c1 = TcpStream::connect(addr).await.unwrap();
        c1.write_all(&hello(ROLE_CONNECT, &token)).await.unwrap();
        let mut c2 = TcpStream::connect(addr).await.unwrap();
        c2.write_all(&hello(ROLE_CONNECT, &token)).await.unwrap();

        // Neither should see PAIRED within a short window.
        let got = tokio::time::timeout(Duration::from_millis(150), read_byte(&mut c1)).await;
        assert!(got.is_err(), "two connects must not pair");

        // An accept with a DIFFERENT token must not grab them either.
        let mut acc = TcpStream::connect(addr).await.unwrap();
        acc.write_all(&hello(ROLE_ACCEPT, &[2u8; TOKEN_LEN]))
            .await
            .unwrap();
        let got = tokio::time::timeout(Duration::from_millis(150), read_byte(&mut acc)).await;
        assert!(got.is_err(), "mismatched token must not pair");
    }

    #[tokio::test]
    async fn health_probe_replies_and_parks_nothing() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let hub = Hub::new(HubConfig {
            park_ttl: Duration::from_millis(300),
        });
        let hub2 = Arc::clone(&hub);
        tokio::spawn(hub.run(listener));

        // The high-level helper succeeds against a live relay.
        health_check(&addr.to_string(), Duration::from_secs(2))
            .await
            .unwrap();

        // And it left no parked state behind.
        assert_eq!(hub2.parked_tokens(), 0, "health probe must not park");
    }

    #[tokio::test]
    async fn rejects_bad_magic() {
        let addr = start_hub().await;
        let mut s = TcpStream::connect(addr).await.unwrap();
        let mut frame = hello(ROLE_CONNECT, &[0u8; TOKEN_LEN]);
        frame[0] = b'X';
        s.write_all(&frame).await.unwrap();
        // The relay drops the connection; reading yields EOF (0 bytes).
        let mut b = [0u8; 1];
        let n = s.read(&mut b).await.unwrap();
        assert_eq!(n, 0, "bad-magic connection should be closed");
    }
}
