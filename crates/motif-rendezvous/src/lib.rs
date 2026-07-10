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

/// Relay → a parked waiter: a keepalive so middleboxes (NAT, L7 proxies, load
/// balancers) on the waiter's path don't reap the idle connection before it is
/// paired. The waiter answers with [`CTRL_PONG`]; both motifd and the Dart
/// client already do.
pub const CTRL_PING: u8 = 0x01;
/// Waiter → relay: the keepalive reply. The relay drains these before splicing.
pub const CTRL_PONG: u8 = 0x02;
/// Sent to both sides at pairing; after it the stream is transparent.
pub const CTRL_PAIRED: u8 = 0x10;
/// Reply to a [`ROLE_HEALTH`] HELLO: the relay's event loop and HELLO parser
/// are alive. Distinct from [`CTRL_PAIRED`] so a probe can't be mistaken for a
/// real pairing.
pub const CTRL_HEALTH_OK: u8 = 0x20;

/// A waiter that has not answered this many consecutive keepalive PINGs is
/// treated as half-open. This bounds stale relay-side state after a peer sleeps
/// or changes networks without the old TCP path delivering a FIN/RST.
const MAX_UNANSWERED_PINGS: u64 = 3;

pub const TOKEN_LEN: usize = 32;
pub const HELLO_LEN: usize = 4 + 1 + 1 + TOKEN_LEN; // 38

pub type Token = [u8; TOKEN_LEN];

/// How long a HELLO is allowed to take before we drop the connection.
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);

/// A parked waiter. The parking task owns the actual `TcpStream` (it keepalives
/// it while waiting); to pair, the opposite-role handler hands *its* stream over
/// this channel, and the parking task splices the two. `tx.is_closed()` becomes
/// true the moment the parking task gives up, so the reaper can prune it.
struct Waiter {
    tx: tokio::sync::oneshot::Sender<TcpStream>,
    since: Instant,
}

#[derive(Default)]
struct Waiters {
    accepts: VecDeque<Waiter>,
    connects: VecDeque<Waiter>,
}

impl Waiters {
    fn is_empty(&self) -> bool {
        self.accepts.is_empty() && self.connects.is_empty()
    }
}

pub struct HubConfig {
    /// Drop a parked (unpaired) connection after it has waited this long. With
    /// keepalive on, healthy parks self-maintain, so this is a long backstop.
    pub park_ttl: Duration,
    /// How often to PING a parked waiter (plus one PING the instant it parks).
    /// `Duration::ZERO` disables keepalive.
    pub keepalive: Duration,
}

impl Default for HubConfig {
    fn default() -> Self {
        Self {
            park_ttl: Duration::from_secs(3600),
            keepalive: Duration::from_secs(15),
        }
    }
}

/// The relay's shared pairing state.
pub struct Hub {
    inner: Mutex<HashMap<Token, Waiters>>,
    park_ttl: Duration,
    keepalive: Duration,
}

impl Hub {
    pub fn new(cfg: HubConfig) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(HashMap::new()),
            park_ttl: cfg.park_ttl,
            keepalive: cfg.keepalive,
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

        // Either pair with an opposite-role waiter that's already parked, or
        // park ourselves. We hand our stream to the parked task (which owns the
        // splice) rather than taking its stream, because that task is busy
        // keepaliving its connection and can't relinquish it mid-`select!`.
        //
        // `rx` is `Some` only when we parked: drive the keepalive loop with it.
        let rx = {
            let mut map = self.inner.lock();
            let w = map.entry(token).or_default();
            let opposite = if role == ROLE_ACCEPT {
                &mut w.connects
            } else {
                &mut w.accepts
            };
            // Hand off to the first *live* parked waiter; a `send` that errors
            // means that task already gave up, so skip it and try the next.
            let mut handed = Some(stream);
            while let Some(waiter) = opposite.pop_front() {
                match waiter.tx.send(handed.take().expect("stream present")) {
                    Ok(()) => break,                          // paired — parked task splices
                    Err(returned) => handed = Some(returned), // dead waiter; retry
                }
            }
            match handed {
                None => {
                    if w.is_empty() {
                        map.remove(&token);
                    }
                    None // paired
                }
                Some(s) => {
                    // No live partner: park ourselves and keepalive until paired.
                    let (tx, rx) = tokio::sync::oneshot::channel();
                    let q = if role == ROLE_ACCEPT {
                        &mut w.accepts
                    } else {
                        &mut w.connects
                    };
                    q.push_back(Waiter {
                        tx,
                        since: Instant::now(),
                    });
                    Some((s, rx))
                }
            }
        };

        if let Some((stream, rx)) = rx {
            park_and_keepalive(stream, rx, self.keepalive).await;
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
                // Drop waiters whose task has exited (`tx` closed) or that have
                // outlived the TTL backstop. Dropping a live `tx` here makes its
                // parking task's `rx` resolve to `Err`, so it closes its socket.
                let keep = |p: &Waiter| !p.tx.is_closed() && now.duration_since(p.since) < ttl;
                w.accepts.retain(keep);
                w.connects.retain(keep);
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

/// Own a parked connection until it pairs. While waiting, PING it periodically
/// (and once immediately) so middleboxes keep the idle connection alive, and
/// drain the waiter's PONG replies. When the opposite-role handler hands us its
/// stream over `rx`, drain any in-flight PONG, then splice the two — so no stray
/// `0x02` leaks into the now-transparent stream.
async fn park_and_keepalive(
    stream: TcpStream,
    mut rx: tokio::sync::oneshot::Receiver<TcpStream>,
    keepalive: Duration,
) {
    let ping_enabled = !keepalive.is_zero();
    let (mut rd, mut wr) = stream.into_split();
    let mut buf = [0u8; 64];
    let mut pings_sent: u64 = 0;
    let mut pongs_read: u64 = 0;

    // Speak first: a single PING right away satisfies proxies that reset a
    // connection whose server stays silent for the first few seconds.
    if ping_enabled {
        if wr.write_all(&[CTRL_PING]).await.is_err() {
            return;
        }
        pings_sent += 1;
    }

    let mut tick = tokio::time::interval(if ping_enabled {
        keepalive
    } else {
        Duration::from_secs(3600)
    });
    tick.tick().await; // the first tick fires immediately — already pinged above

    let partner = loop {
        tokio::select! {
            // Prefer already-queued PONG/PAIRED work over the timer when they
            // become ready together, so scheduler jitter cannot manufacture a
            // missed keepalive at the deadline.
            biased;
            p = &mut rx => match p {
                Ok(partner) => break partner,
                Err(_) => return, // reaper pruned us (TTL) or hub dropped
            },
            r = rd.read(&mut buf) => match r {
                Ok(0) | Err(_) => return, // peer closed while parked
                Ok(n) => pongs_read += count_pongs(&buf[..n]),
            },
            _ = tick.tick(), if ping_enabled => {
                let unanswered = pings_sent.saturating_sub(pongs_read);
                if unanswered >= MAX_UNANSWERED_PINGS {
                    tracing::debug!(
                        unanswered,
                        "rzv: parked waiter missed keepalives; closing half-open socket"
                    );
                    return;
                }
                if wr.write_all(&[CTRL_PING]).await.is_err() {
                    return; // peer gone
                }
                pings_sent += 1;
            },
        }
    };

    // Consume PONGs still owed for PINGs we sent, so copy_bidirectional doesn't
    // forward a leftover 0x02 to the partner. Bounded so a silent peer can't
    // wedge the splice.
    if ping_enabled && pongs_read < pings_sent {
        let drain = async {
            while pongs_read < pings_sent {
                match rd.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => pongs_read += count_pongs(&buf[..n]),
                }
            }
        };
        let _ = tokio::time::timeout(Duration::from_millis(500), drain).await;
    }

    // The halves come from the same stream, so reunite never errors.
    if let Ok(stream) = rd.reunite(wr) {
        splice(stream, partner).await;
    }
}

fn count_pongs(bytes: &[u8]) -> u64 {
    bytes.iter().filter(|&&b| b == CTRL_PONG).count() as u64
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

    async fn spawn_hub(keepalive: Duration) -> (std::net::SocketAddr, Arc<Hub>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        // Long TTL so the (30s-tick) reaper never fires mid-test.
        let hub = Hub::new(HubConfig {
            park_ttl: Duration::from_secs(30),
            keepalive,
        });
        let handle = Arc::clone(&hub);
        tokio::spawn(hub.run(listener));
        (addr, handle)
    }

    /// Most tests don't care about keepalive; default it off so a parked waiter
    /// emits no PING noise.
    async fn start_hub() -> std::net::SocketAddr {
        spawn_hub(Duration::ZERO).await.0
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
        let (addr, hub) = spawn_hub(Duration::ZERO).await;

        // The high-level helper succeeds against a live relay.
        health_check(&addr.to_string(), Duration::from_secs(2))
            .await
            .unwrap();

        // And it left no parked state behind.
        assert_eq!(hub.parked_tokens(), 0, "health probe must not park");
    }

    #[tokio::test]
    async fn relay_pings_a_lone_park() {
        let (addr, hub) = spawn_hub(Duration::from_millis(40)).await;
        let token = [9u8; TOKEN_LEN];

        let mut acc = TcpStream::connect(addr).await.unwrap();
        acc.write_all(&hello(ROLE_ACCEPT, &token)).await.unwrap();

        // The relay speaks first: a parked, partnerless waiter still gets a PING
        // so a middlebox doesn't reap the idle connection.
        assert_eq!(read_byte(&mut acc).await, CTRL_PING);
        assert_eq!(hub.parked_tokens(), 1, "the waiter stays parked");
    }

    #[tokio::test]
    async fn relay_closes_waiter_that_stops_answering_pings() {
        let (addr, _hub) = spawn_hub(Duration::from_millis(20)).await;
        let token = [11u8; TOKEN_LEN];

        let mut acc = TcpStream::connect(addr).await.unwrap();
        acc.write_all(&hello(ROLE_ACCEPT, &token)).await.unwrap();

        // Do not send any PONGs. The immediate PING plus two interval PINGs
        // exhaust the allowance; at the next tick the relay must close rather
        // than retain a zombie waiter indefinitely.
        for _ in 0..MAX_UNANSWERED_PINGS {
            assert_eq!(read_byte(&mut acc).await, CTRL_PING);
        }
        let mut byte = [0u8; 1];
        let n = tokio::time::timeout(Duration::from_millis(200), acc.read(&mut byte))
            .await
            .expect("relay did not reap the unresponsive waiter")
            .unwrap();
        assert_eq!(n, 0, "relay should close after unanswered PINGs");
    }

    #[tokio::test]
    async fn keepalive_park_pairs_without_leaking_pong() {
        let (addr, _hub) = spawn_hub(Duration::from_millis(20)).await;
        let token = [5u8; TOKEN_LEN];

        // Emulate motifd: park an accept and answer PINGs with PONGs in real
        // time. Once paired, verify the client's bytes arrive EXACTLY — a leaked
        // PONG would corrupt the now-transparent stream.
        let mut acc = TcpStream::connect(addr).await.unwrap();
        acc.write_all(&hello(ROLE_ACCEPT, &token)).await.unwrap();
        let acc_task = tokio::spawn(async move {
            loop {
                match read_byte(&mut acc).await {
                    CTRL_PAIRED => break,
                    CTRL_PING => acc.write_all(&[CTRL_PONG]).await.unwrap(),
                    b => panic!("acc: unexpected pre-pair byte {b:#04x}"),
                }
            }
            let mut buf = [0u8; 5];
            acc.read_exact(&mut buf).await.unwrap();
            assert_eq!(&buf, b"hello", "client->server payload corrupted");
            acc.write_all(b"world").await.unwrap();
        });

        // Let the relay PING the park several times first.
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Client dials in and pairs. It never parked, so its first byte is PAIRED.
        let mut con = TcpStream::connect(addr).await.unwrap();
        con.write_all(&hello(ROLE_CONNECT, &token)).await.unwrap();
        assert_eq!(read_byte(&mut con).await, CTRL_PAIRED);
        con.write_all(b"hello").await.unwrap();
        let mut buf = [0u8; 5];
        con.read_exact(&mut buf).await.unwrap();
        assert_eq!(
            &buf, b"world",
            "server->client payload corrupted (leaked PONG?)"
        );

        acc_task.await.unwrap();
    }

    #[tokio::test]
    async fn dead_park_is_skipped_when_pairing() {
        let (addr, _hub) = spawn_hub(Duration::from_millis(20)).await;
        let token = [3u8; TOKEN_LEN];

        // Park an accept, confirm it's live (got a PING), then drop it so its
        // park task exits and its hand-off channel closes.
        {
            let mut dead = TcpStream::connect(addr).await.unwrap();
            dead.write_all(&hello(ROLE_ACCEPT, &token)).await.unwrap();
            assert_eq!(read_byte(&mut dead).await, CTRL_PING);
        }
        tokio::time::sleep(Duration::from_millis(40)).await; // let the task notice EOF

        // A connect must skip the dead waiter and park itself (getting a PING),
        // not pair with — or hang on — the corpse.
        let mut con = TcpStream::connect(addr).await.unwrap();
        con.write_all(&hello(ROLE_CONNECT, &token)).await.unwrap();
        assert_eq!(
            read_byte(&mut con).await,
            CTRL_PING,
            "connect should skip the dead accept and park (be pinged), not pair"
        );
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
