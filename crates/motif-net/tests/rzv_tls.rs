//! End-to-end TLS over the rzv pipe: motifd terminates a real rustls handshake
//! on the accept side, and a pinning client reaches it through the relay. The
//! relay only ever sees ciphertext.

use std::sync::Arc;

use axum::serve::Listener as _;
use motif_net::{ListenConfig, RzvListenConfig};
use motif_rendezvous::{Hub, HubConfig, CTRL_PAIRED, MAGIC, ROLE_CONNECT, VERSION};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;

#[tokio::test]
async fn rzv_tls_pins_and_pipes_through_relay() {
    // Real relay.
    let relay = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_addr = relay.local_addr().unwrap();
    tokio::spawn(Hub::new(HubConfig::default()).run(relay));

    // motifd-side identity: a self-signed cert + a rustls server config.
    let cert = rcgen::generate_simple_self_signed(vec!["motif-rzv".to_string()]).unwrap();
    let cert_der = cert.cert.der().as_ref().to_vec();
    let mut pin = [0u8; 32];
    pin.copy_from_slice(&Sha256::digest(&cert_der));
    let key = rustls::pki_types::PrivateKeyDer::Pkcs8(
        rustls::pki_types::PrivatePkcs8KeyDer::from(cert.key_pair.serialize_der()),
    );
    let server_config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![CertificateDer::from(cert_der)], key)
    .unwrap();

    let token = [42u8; 32];
    let mut listener = motif_net::Listener::bind(&ListenConfig {
        tcp: None,
        tcp_tls: None,
        tailscale: None,
        rendezvous: Some(RzvListenConfig {
            url: relay_addr.to_string(),
            token,
            pool: 2,
            tls: Some(Arc::new(server_config)),
        }),
    })
    .await
    .unwrap();

    // Pinning client: dial relay, pair, then TLS-handshake to motifd.
    let client = tokio::spawn(async move {
        let mut s = TcpStream::connect(relay_addr).await.unwrap();
        let mut hello = Vec::new();
        hello.extend_from_slice(&MAGIC);
        hello.push(VERSION);
        hello.push(ROLE_CONNECT);
        hello.extend_from_slice(&token);
        s.write_all(&hello).await.unwrap();
        s.flush().await.unwrap();
        let mut paired = [0u8; 1];
        s.read_exact(&mut paired).await.unwrap();
        assert_eq!(paired[0], CTRL_PAIRED);

        let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinVerifier { expected: pin }))
        .with_no_client_auth();

        let connector = TlsConnector::from(Arc::new(cfg));
        let server_name = ServerName::try_from("motif-rzv").unwrap();
        let mut tls = connector.connect(server_name, s).await.unwrap();
        tls.write_all(b"hi").await.unwrap();
        tls.flush().await.unwrap();
        let mut buf = [0u8; 5];
        tls.read_exact(&mut buf).await.unwrap();
        buf
    });

    // Server side: the accepted Stream is already TLS-terminated.
    let (mut stream, _addr) = listener.accept().await;
    let mut got = [0u8; 2];
    stream.read_exact(&mut got).await.unwrap();
    assert_eq!(&got, b"hi");
    stream.write_all(b"hi-ok").await.unwrap();
    stream.flush().await.unwrap();

    assert_eq!(&client.await.unwrap(), b"hi-ok");
}

/// Accepts exactly the cert whose DER hashes to `expected` — the pin the client
/// would carry in the pairing QR.
#[derive(Debug)]
struct PinVerifier {
    expected: [u8; 32],
}

impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let got = Sha256::digest(end_entity.as_ref());
        if got.as_slice() == self.expected {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("rzv cert pin mismatch".into()))
        }
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
