//! End-to-end TLS carried inside the authenticated rendezvous WebSockets.

mod common;

use std::sync::Arc;

use axum::serve::Listener as _;
use motif_net::{ListenConfig, RzvListenConfig};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_rustls::TlsConnector;

#[tokio::test]
async fn rzv_tls_pins_and_pipes_through_relay() {
    let relay = common::start_relay().await;
    let cert = rcgen::generate_simple_self_signed(vec!["motif-rzv".to_string()]).unwrap();
    let cert_der = cert.cert.der().as_ref().to_vec();
    let mut pin = [0u8; 32];
    pin.copy_from_slice(&Sha256::digest(&cert_der));
    let key = rustls::pki_types::PrivateKeyDer::Pkcs8(rustls::pki_types::PrivatePkcs8KeyDer::from(
        cert.key_pair.serialize_der(),
    ));
    let server_config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![CertificateDer::from(cert_der)], key)
    .unwrap();

    let token = [42u8; 32];
    let mut rzv = RzvListenConfig::new(format!("ws://{}", relay.addr), token, relay.jwt);
    rzv.tls = Some(Arc::new(server_config));
    let mut listener = motif_net::Listener::bind(&ListenConfig {
        tcp: None,
        tcp_tls: None,
        tailscale: None,
        rendezvous: Some(rzv),
    })
    .await
    .unwrap();

    let relay_addr = relay.addr;
    let client = tokio::spawn(async move {
        let ws = common::connect_client(relay_addr, &token).await;
        let stream = common::websocket_byte_stream(ws);
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
        let mut tls = connector.connect(server_name, stream).await.unwrap();
        tls.write_all(b"hi").await.unwrap();
        tls.flush().await.unwrap();
        let mut buf = [0u8; 5];
        tls.read_exact(&mut buf).await.unwrap();
        buf
    });

    let (mut stream, _addr) = listener.accept().await;
    let mut got = [0u8; 2];
    stream.read_exact(&mut got).await.unwrap();
    assert_eq!(&got, b"hi");
    stream.write_all(b"hi-ok").await.unwrap();
    stream.flush().await.unwrap();
    assert_eq!(&client.await.unwrap(), b"hi-ok");
}

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
