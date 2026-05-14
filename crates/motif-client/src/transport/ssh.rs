//! SSH local-forward tunnel. Invokes the system `ssh` binary as a subprocess
//! (delegates auth/config to ~/.ssh/config + ssh-agent — see docs/ssh-tunnel.md).

use std::net::{SocketAddr, TcpListener};
use std::process::Stdio;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};

const READY_TIMEOUT: Duration = Duration::from_secs(15);
const POLL: Duration = Duration::from_millis(50);

pub struct SshTunnel {
    child: Child,
    local_port: u16,
}

impl SshTunnel {
    pub async fn open(target: &str, remote_port: u16) -> anyhow::Result<Self> {
        which::which("ssh").map_err(|_| {
            anyhow!("system `ssh` binary not found in PATH; install OpenSSH or use --via direct")
        })?;

        let local_port = pick_local_port()?;
        let (user_host, ssh_port) = parse_target(target);

        let mut cmd = Command::new("ssh");
        cmd.arg("-N")
            .arg("-o")
            .arg("ExitOnForwardFailure=yes")
            .arg("-o")
            .arg("ServerAliveInterval=30")
            .arg("-o")
            .arg("ServerAliveCountMax=3")
            .arg("-L")
            .arg(format!("{local_port}:127.0.0.1:{remote_port}"));
        if let Some(p) = ssh_port {
            cmd.arg("-p").arg(p.to_string());
        }
        cmd.arg(&user_host);
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::null());
        cmd.stderr(Stdio::piped());
        cmd.kill_on_drop(true);

        let mut child = cmd.spawn().with_context(|| {
            format!("spawning ssh -L {local_port}:127.0.0.1:{remote_port} {user_host}")
        })?;

        // Capture stderr so we can surface auth errors if the tunnel never opens.
        let stderr = child.stderr.take();

        let deadline = Instant::now() + READY_TIMEOUT;
        loop {
            if let Ok(Some(status)) = child.try_wait() {
                let mut buf = String::new();
                if let Some(mut e) = stderr {
                    let _ = e.read_to_string(&mut buf).await;
                }
                anyhow::bail!(
                    "ssh exited before tunnel ready (status={status}): {}",
                    buf.trim()
                );
            }
            if std::net::TcpStream::connect_timeout(
                &SocketAddr::from(([127, 0, 0, 1], local_port)),
                Duration::from_millis(200),
            )
            .is_ok()
            {
                return Ok(Self { child, local_port });
            }
            if Instant::now() >= deadline {
                let _ = child.kill().await;
                anyhow::bail!("ssh tunnel did not open within {:?}", READY_TIMEOUT);
            }
            tokio::time::sleep(POLL).await;
        }
    }

    pub fn local_ws_url(&self) -> String {
        format!("ws://127.0.0.1:{}/", self.local_port)
    }

    pub fn local_port(&self) -> u16 {
        self.local_port
    }
}

impl Drop for SshTunnel {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

fn pick_local_port() -> anyhow::Result<u16> {
    let l = TcpListener::bind("127.0.0.1:0")?;
    let port = l.local_addr()?.port();
    drop(l);
    Ok(port)
}

fn parse_target(s: &str) -> (String, Option<u16>) {
    if let Some((host, port)) = s.rsplit_once(':') {
        if let Ok(p) = port.parse::<u16>() {
            return (host.to_string(), Some(p));
        }
    }
    (s.to_string(), None)
}
