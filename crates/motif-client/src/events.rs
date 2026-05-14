//! `WS /events?session=<sid>&since=<seq>` subscriber.
//!
//! Pushes typed `Event` values into a caller-supplied channel. The
//! receiving side owns the rx, so the coordinator (or any consumer)
//! can fold events into its own dispatch stream without giving up
//! ownership of an mpsc::Receiver to a black box.

use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use futures_util::sink::Sink;
use futures_util::stream::Stream as FuturesStream;
use futures_util::{SinkExt, StreamExt};
use motif_proto::common::Seq;
use motif_proto::envelope::Notification;
use motif_proto::event::Event;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_tungstenite::{
    client_async, tungstenite::client::IntoClientRequest, tungstenite::http::HeaderValue,
    tungstenite::Message,
};

const PING_INTERVAL: Duration = Duration::from_secs(20);
const IDLE_TIMEOUT: Duration = Duration::from_secs(45);
const HEARTBEAT_TICK: Duration = Duration::from_secs(10);

type WsErr = tokio_tungstenite::tungstenite::Error;
type WsSink = Pin<Box<dyn Sink<Message, Error = WsErr> + Send>>;
type WsRx = Pin<Box<dyn FuturesStream<Item = Result<Message, WsErr>> + Send>>;

/// Holds the background tasks for one `/events` connection. Dropping
/// aborts them all. The caller owns the mpsc::Receiver that frames
/// land on.
pub struct EventsClient {
    /// Last seq observed (server-monotonic). Updated by the reader
    /// task; readable via [`last_seq`].
    pub(crate) last_seq: Arc<Mutex<Seq>>,
    reader: tokio::task::JoinHandle<()>,
    writer: tokio::task::JoinHandle<()>,
    heartbeat: tokio::task::JoinHandle<()>,
}

impl Drop for EventsClient {
    fn drop(&mut self) {
        self.reader.abort();
        self.writer.abort();
        self.heartbeat.abort();
    }
}

impl EventsClient {
    pub fn last_seq(&self) -> Seq {
        *self.last_seq.lock().unwrap()
    }

    pub async fn connect_tcp(
        addr: &str,
        token: &str,
        session_id: &str,
        since: Seq,
        event_tx: mpsc::UnboundedSender<Event>,
    ) -> anyhow::Result<Self> {
        let stream = TcpStream::connect(addr)
            .await
            .with_context(|| format!("dial {}", addr))?;
        Self::connect_with_stream(addr, token, session_id, since, event_tx, stream).await
    }

    pub async fn connect_with_stream<S>(
        authority: &str,
        token: &str,
        session_id: &str,
        since: Seq,
        event_tx: mpsc::UnboundedSender<Event>,
        stream: S,
    ) -> anyhow::Result<Self>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let url = format!("ws://{authority}/events?session={session_id}&since={since}");
        let mut req = url
            .as_str()
            .into_client_request()
            .with_context(|| format!("invalid url: {url}"))?;
        req.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|e| anyhow!("invalid token: {e}"))?,
        );
        let (ws, _resp) = client_async(req, stream)
            .await
            .context("/events ws handshake")?;
        let (tx, rx) = ws.split();

        let last_seq = Arc::new(Mutex::new(since));
        let (out_tx, out_rx) = mpsc::unbounded_channel::<Message>();
        let liveness = Arc::new(Mutex::new(Instant::now()));

        let reader = tokio::spawn(reader_task(
            Box::pin(rx),
            event_tx,
            Arc::clone(&last_seq),
            Arc::clone(&liveness),
        ));
        let writer = tokio::spawn(writer_task(Box::pin(tx), out_rx));
        let heartbeat = tokio::spawn(heartbeat_task(out_tx, liveness));

        Ok(Self {
            last_seq,
            reader,
            writer,
            heartbeat,
        })
    }
}

async fn reader_task(
    mut ws_rx: WsRx,
    event_tx: mpsc::UnboundedSender<Event>,
    last_seq: Arc<Mutex<Seq>>,
    liveness: Arc<Mutex<Instant>>,
) {
    while let Some(item) = ws_rx.next().await {
        let msg = match item {
            Ok(m) => m,
            Err(e) => {
                tracing::debug!(error = %e, "/events read");
                break;
            }
        };
        *liveness.lock().unwrap() = Instant::now();
        let text = match msg {
            Message::Text(t) => t.to_string(),
            Message::Binary(_) | Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {
                continue
            }
            Message::Close(_) => break,
        };
        let notif: Notification = match serde_json::from_str(&text) {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!(error = %e, "events: bad frame");
                continue;
            }
        };
        let event_value = serde_json::json!({
            "method": notif.method,
            "params": notif.params,
        });
        let event: Event = match serde_json::from_value(event_value) {
            Ok(e) => e,
            Err(e) => {
                tracing::warn!(error = %e, "events: unknown variant");
                continue;
            }
        };
        let seq = event.seq();
        {
            let mut cur = last_seq.lock().unwrap();
            if seq > *cur {
                *cur = seq;
            }
        }
        if event_tx.send(event).is_err() {
            break;
        }
    }
}

async fn writer_task(mut ws_tx: WsSink, mut out_rx: mpsc::UnboundedReceiver<Message>) {
    while let Some(msg) = out_rx.recv().await {
        if ws_tx.send(msg).await.is_err() {
            return;
        }
    }
}

async fn heartbeat_task(out_tx: mpsc::UnboundedSender<Message>, liveness: Arc<Mutex<Instant>>) {
    let mut ticker = tokio::time::interval(HEARTBEAT_TICK);
    ticker.tick().await;
    let mut next_ping = Instant::now() + PING_INTERVAL;
    loop {
        ticker.tick().await;
        let now = Instant::now();
        let idle = now.duration_since(*liveness.lock().unwrap());
        if idle > IDLE_TIMEOUT {
            let _ = out_tx.send(Message::Close(None));
            return;
        }
        if now >= next_ping {
            if out_tx.send(Message::Ping(Default::default())).is_err() {
                return;
            }
            next_ping = now + PING_INTERVAL;
        }
    }
}
