//! Client-side dial. Takes a [`DialTarget`] and returns a connected
//! [`Stream`].

use crate::config::DialTarget;
use crate::stream::Stream;

#[derive(Debug, thiserror::Error)]
pub enum NetError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[cfg(feature = "tailscale")]
    #[error("tailscale: {0}")]
    Tailscale(#[from] motif_tailscale::TsError),
}

pub async fn dial(target: &DialTarget) -> Result<Stream, NetError> {
    match target {
        DialTarget::Tcp(addr) => {
            let sock = tokio::net::TcpStream::connect(addr).await?;
            Ok(Stream::from_tcp(sock))
        }
        #[cfg(feature = "tailscale")]
        DialTarget::Tailscale { addr, server } => {
            let s = server.dial_tcp(addr).await?;
            Ok(Stream::from_tailscale(s))
        }
    }
}
