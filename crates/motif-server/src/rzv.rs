//! Rendezvous pairing helpers: derive the on-the-wire rzv token from the
//! pairing secret, and render the `motif://pair` link / QR.
//!
//! The token is **one-way** derived from the pairing secret (`psk`) so the
//! relay — which sees the token — never learns the `psk`. The `psk` is the
//! durable secret reserved for the future end-to-end layer (P2 TLS pin); it
//! must never appear on the wire. Keep this derivation byte-identical with the
//! Dart client (`RzvProtocol.deriveToken`) and `docs/rzv-protocol.md`.

use std::path::Path;
use std::sync::Arc;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::ServerConfig;
use sha2::{Digest, Sha256};

const TOKEN_INFO: &[u8] = b"motif-rzv-token-v1";

/// motifd's persisted self-signed identity for rzv end-to-end TLS.
pub struct RzvIdentity {
    /// rustls server config used to terminate TLS on the relayed pipe.
    pub server_config: Arc<ServerConfig>,
    /// SHA-256 of the certificate DER — the pin the client carries in the QR
    /// (`pk`) and checks the presented cert against.
    pub cert_sha256: [u8; 32],
}

/// Load the persisted identity (cert.der + key.der under `dir`), or generate a
/// fresh self-signed pair and persist it. Stable across restarts so the pin in
/// the pairing QR keeps matching.
pub fn load_or_create_identity(dir: &Path) -> anyhow::Result<RzvIdentity> {
    let cert_path = dir.join("rzv_cert.der");
    let key_path = dir.join("rzv_key.der");

    let (cert_der, key_der) = match (std::fs::read(&cert_path), std::fs::read(&key_path)) {
        (Ok(c), Ok(k)) if !c.is_empty() && !k.is_empty() => (c, k),
        _ => {
            let certified = rcgen::generate_simple_self_signed(vec!["motif-rzv".to_string()])
                .map_err(|e| anyhow::anyhow!("generate self-signed cert: {e}"))?;
            let cert_der = certified.cert.der().as_ref().to_vec();
            let key_der = certified.key_pair.serialize_der();
            std::fs::create_dir_all(dir).ok();
            std::fs::write(&cert_path, &cert_der)
                .map_err(|e| anyhow::anyhow!("write {}: {e}", cert_path.display()))?;
            std::fs::write(&key_path, &key_der)
                .map_err(|e| anyhow::anyhow!("write {}: {e}", key_path.display()))?;
            (cert_der, key_der)
        }
    };

    let mut cert_sha256 = [0u8; 32];
    cert_sha256.copy_from_slice(&Sha256::digest(&cert_der));

    let certs = vec![CertificateDer::from(cert_der)];
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_der));
    let server_config = ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|e| anyhow::anyhow!("rustls protocol versions: {e}"))?
    .with_no_client_auth()
    .with_single_cert(certs, key)
    .map_err(|e| anyhow::anyhow!("rustls server config: {e}"))?;

    Ok(RzvIdentity {
        server_config: Arc::new(server_config),
        cert_sha256,
    })
}

/// HKDF-SHA256 (RFC 5869) with an empty salt, L = 32 — the rzv token.
pub fn derive_token(psk: &[u8; 32]) -> [u8; 32] {
    // Extract: salt defaults to HashLen (32) zero bytes when not provided.
    let prk = hmac_sha256(&[0u8; 32], psk);
    // Expand: L == HashLen, so a single block T(1) = HMAC(PRK, info | 0x01).
    let mut info_ctr = Vec::with_capacity(TOKEN_INFO.len() + 1);
    info_ctr.extend_from_slice(TOKEN_INFO);
    info_ctr.push(0x01);
    hmac_sha256(&prk, &info_ctr)
}

/// Build the `motif://pair` URI a client scans/pastes to learn where to meet
/// (`rzv`), the pairing secret (`psk`), and — when end-to-end TLS is on — the
/// cert pin to verify motifd against (`pk` = SHA-256 of the cert DER).
pub fn pair_uri(relay: &str, psk: &[u8; 32], pin: Option<&[u8; 32]>, name: Option<&str>) -> String {
    let psk_b64 = URL_SAFE_NO_PAD.encode(psk);
    let mut uri = format!("motif://pair?v=1&rzv={relay}&psk={psk_b64}");
    if let Some(pin) = pin {
        uri.push_str(&format!("&pk={}", URL_SAFE_NO_PAD.encode(pin)));
    }
    if let Some(n) = name {
        // Names here are hostnames/identifiers — keep it simple, percent-encode
        // the few characters that would break the query.
        let n = n.replace('&', "%26").replace(' ', "%20");
        uri.push_str(&format!("&name={n}"));
    }
    uri
}

/// Load the persisted pairing secret from `path`, or generate a fresh 32-byte
/// secret and persist it (base64url). A malformed/short file is replaced.
pub fn load_or_create_psk(path: &Path) -> anyhow::Result<[u8; 32]> {
    if let Ok(s) = std::fs::read_to_string(path) {
        if let Ok(bytes) = URL_SAFE_NO_PAD.decode(s.trim()) {
            if let Ok(arr) = <[u8; 32]>::try_from(bytes.as_slice()) {
                return Ok(arr);
            }
        }
        tracing::warn!(path = %path.display(), "rzv: psk file unreadable; regenerating");
    }
    let mut psk = [0u8; 32];
    getrandom::getrandom(&mut psk).map_err(|e| anyhow::anyhow!("getrandom: {e}"))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    std::fs::write(path, URL_SAFE_NO_PAD.encode(psk))
        .map_err(|e| anyhow::anyhow!("write psk {}: {e}", path.display()))?;
    Ok(psk)
}

/// Render `uri` as a terminal QR (unicode half-blocks), or `None` if it won't
/// encode. Dark-on-light with a quiet zone so it scans on a light terminal;
/// the printed link is the fallback on dark backgrounds.
pub fn render_qr(uri: &str) -> Option<String> {
    use qrcode::render::unicode;
    use qrcode::QrCode;
    let code = QrCode::new(uri.as_bytes()).ok()?;
    Some(
        code.render::<unicode::Dense1x2>()
            .quiet_zone(true)
            .build(),
    )
}

fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    const B: usize = 64; // SHA-256 block size
    let mut k = [0u8; B];
    if key.len() > B {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; B];
    let mut opad = [0x5cu8; B];
    for i in 0..B {
        ipad[i] ^= k[i];
        opad[i] ^= k[i];
    }
    let inner = {
        let mut h = Sha256::new();
        h.update(ipad);
        h.update(msg);
        h.finalize()
    };
    let mut out = [0u8; 32];
    let mut h = Sha256::new();
    h.update(opad);
    h.update(inner);
    out.copy_from_slice(&h.finalize());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_matches_rfc4231_test_case_2() {
        // RFC 4231 test case 2: key="Jefe", data="what do ya want for nothing?"
        let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
        let hex: String = mac.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            hex,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn token_derivation_is_stable_and_one_way() {
        // Cross-language fixed vector — must match the Dart test exactly.
        let psk: [u8; 32] = std::array::from_fn(|i| i as u8);
        let token = derive_token(&psk);
        let hex: String = token.iter().map(|b| format!("{b:02x}")).collect();
        // The token is not the psk (one-way).
        assert_ne!(token, psk);
        assert_eq!(
            hex,
            "bb48b13937710e30c1fffa843593313a7d403c44236eb01d6c86842e43bfa7da",
            "update both this and the Dart fixture if the derivation changes"
        );
    }

    #[test]
    fn pair_uri_round_trips_shape() {
        let psk: [u8; 32] = [7u8; 32];
        let uri = pair_uri("relay.example:9999", &psk, None, Some("studio"));
        assert!(uri.starts_with("motif://pair?v=1&rzv=relay.example:9999&psk="));
        assert!(uri.contains("&name=studio"));
        assert!(!uri.contains("&pk="));

        let pin: [u8; 32] = [9u8; 32];
        let uri = pair_uri("r:1", &psk, Some(&pin), None);
        assert!(uri.contains("&pk="));
        assert!(!uri.contains("&name="));
    }
}
