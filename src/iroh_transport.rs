//! Device-bound iroh transport. Each bidirectional stream carries one bounded
//! request to the existing router; no arbitrary TCP forwarding is exposed.
use crate::*;
use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use iroh::{Endpoint, SecretKey, endpoint::presets};
use serde_json::{Value, json};
use std::{collections::HashMap, sync::Mutex as StdMutex, time::Duration};
use tower::ServiceExt;

pub const PAIR_ALPN: &[u8] = b"agentmux/pair/1";
pub const API_ALPN: &[u8] = b"agentmux/api/1";
const HEADER_LIMIT: usize = 8192;
const CHUNK_LIMIT: usize = 65536;
const TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Settings {
    #[serde(default)]
    pub enabled: bool,
    /// None uses public discovery/relays; [] is direct-only and offline-testable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay_urls: Option<Vec<String>>,
}

struct Ticket {
    hash: String,
    expires: u64,
}
pub struct Manager {
    directory: PathBuf,
    endpoint: Mutex<Option<Endpoint>>,
    tickets: StdMutex<Option<Ticket>>,
    connections: StdMutex<HashMap<usize, (String, iroh::endpoint::Connection)>>,
    permits: Arc<tokio::sync::Semaphore>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct PairCode {
    pub version: u8,
    pub transport: String,
    pub name: String,
    pub endpoint_id: String,
    pub relay_url: Option<String>,
    pub addresses: Vec<String>,
    pub relay_urls: Option<Vec<String>>,
    pub ticket: String,
    pub expires: u64,
}

#[derive(Deserialize)]
struct PairRequest {
    version: u8,
    ticket: String,
    name: String,
}
#[derive(Serialize, Deserialize)]
struct ApiRequest {
    version: u8,
    method: String,
    path: String,
    token: String,
    #[serde(default)]
    length: usize,
}

impl Manager {
    pub fn new(directory: PathBuf) -> Self {
        Self {
            directory,
            endpoint: Mutex::new(None),
            tickets: StdMutex::new(None),
            connections: StdMutex::new(HashMap::new()),
            permits: Arc::new(tokio::sync::Semaphore::new(32)),
        }
    }

    pub async fn start(self: &Arc<Self>, app: Shared) -> Result<Endpoint> {
        let mut active = self.endpoint.lock().await;
        if let Some(endpoint) = active.as_ref() {
            return Ok(endpoint.clone());
        }
        let settings = app.config.lock().await.iroh.clone().unwrap_or_default();
        let path = self.directory.join("iroh.key");
        let key = if path.exists() {
            let bytes: [u8; 32] = std::fs::read(&path)
                .map_err(internal)?
                .try_into()
                .map_err(|_| internal("Invalid iroh identity key; restore it from backup"))?;
            SecretKey::from_bytes(&bytes)
        } else {
            let bytes: [u8; 32] = rand::random();
            pairing::private_write(&path, &bytes).map_err(internal)?;
            SecretKey::from_bytes(&bytes)
        };
        let mut builder = if settings.relay_urls.as_ref().is_some_and(Vec::is_empty) {
            Endpoint::builder(presets::Minimal)
        } else {
            Endpoint::builder(presets::N0)
        };
        if let Some(urls) = &settings.relay_urls {
            let urls = urls
                .iter()
                .map(|url| url.parse::<iroh::RelayUrl>())
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(bad)?;
            builder = builder.relay_mode(if urls.is_empty() {
                iroh::RelayMode::Disabled
            } else {
                iroh::RelayMode::Custom(urls.into_iter().collect())
            });
        }
        let endpoint = builder
            .secret_key(key)
            .alpns(vec![PAIR_ALPN.to_vec(), API_ALPN.to_vec()])
            .bind()
            .await
            .map_err(internal)?;
        *active = Some(endpoint.clone());
        let manager = self.clone();
        let acceptor = endpoint.clone();
        tokio::spawn(async move {
            while let Some(incoming) = acceptor.accept().await {
                let Ok(permit) = manager.permits.clone().try_acquire_owned() else {
                    incoming.refuse();
                    continue;
                };
                let app = app.clone();
                let manager = manager.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Ok(Ok(connection)) = tokio::time::timeout(TIMEOUT, incoming).await {
                        manager.handle_connection(app, connection).await;
                    }
                });
            }
        });
        eprintln!("iroh enabled; endpoint {}", endpoint.id());
        Ok(endpoint)
    }

    async fn handle_connection(
        self: Arc<Self>,
        app: Shared,
        connection: iroh::endpoint::Connection,
    ) {
        let peer = connection.remote_id().to_string();
        let pairing = connection.alpn() == PAIR_ALPN;
        if !pairing && !app.pairing.known_peer(&peer) {
            connection.close(1u32.into(), b"Pair this device first");
            return;
        }
        let id = connection.stable_id();
        self.connections
            .lock()
            .unwrap()
            .insert(id, (peer.clone(), connection.clone()));
        let slots = Arc::new(tokio::sync::Semaphore::new(if pairing { 1 } else { 16 }));
        loop {
            let (send, recv) = match tokio::time::timeout(
                Duration::from_secs(if pairing { 15 } else { 300 }),
                connection.accept_bi(),
            )
            .await
            {
                Ok(Ok(stream)) => stream,
                Err(_) if !pairing && slots.available_permits() < 16 => continue,
                _ => break,
            };
            let Ok(permit) = slots.clone().try_acquire_owned() else {
                break;
            };
            let app = app.clone();
            let manager = self.clone();
            let peer = peer.clone();
            tokio::spawn(async move {
                let _permit = permit;
                let _ = manager.handle_stream(app, &peer, pairing, send, recv).await;
            });
            if pairing {
                break;
            }
        }
        if pairing {
            let _ = tokio::time::timeout(Duration::from_secs(30), connection.closed()).await;
        }
        self.connections.lock().unwrap().remove(&id);
        connection.close(0u32.into(), b"Disconnected");
    }

    async fn handle_stream(
        &self,
        app: Shared,
        peer: &str,
        pairing: bool,
        mut send: iroh::endpoint::SendStream,
        mut recv: iroh::endpoint::RecvStream,
    ) -> Result<()> {
        let header = tokio::time::timeout(TIMEOUT, read_packet(&mut recv, HEADER_LIMIT))
            .await
            .map_err(internal)??;
        let response = if pairing {
            let request: PairRequest = serde_json::from_slice(&header).map_err(bad)?;
            let tail = tokio::time::timeout(TIMEOUT, recv.read_to_end(1))
                .await
                .map_err(internal)?
                .map_err(bad)?;
            if !tail.is_empty() {
                return Err(bad("Unexpected pairing bytes"));
            }
            let result = self.complete(&app.pairing, peer, request);
            match result {
                Ok(value) => axum::response::IntoResponse::into_response(Json(value)),
                Err(error) => axum::response::IntoResponse::into_response(error),
            }
        } else {
            let request: ApiRequest = serde_json::from_slice(&header).map_err(bad)?;
            if let Err(error) = validate_request(&request, peer, &app.pairing) {
                return send_response(
                    &mut send,
                    axum::response::IntoResponse::into_response(error),
                )
                .await;
            }
            let mut body = vec![0; request.length];
            tokio::time::timeout(TIMEOUT, recv.read_exact(&mut body))
                .await
                .map_err(internal)?
                .map_err(bad)?;
            let tail = tokio::time::timeout(TIMEOUT, recv.read_to_end(1))
                .await
                .map_err(internal)?
                .map_err(bad)?;
            if !tail.is_empty() {
                return Err(bad("Unexpected request bytes"));
            }
            // Recheck immediately before dispatch, including after a slow upload.
            if !app.pairing.valid_peer(&request.token, peer) {
                return Err((StatusCode::UNAUTHORIZED, "Device revoked".into()));
            }
            let http = Request::builder()
                .method(request.method.as_str())
                .uri(&request.path)
                .header("Authorization", format!("Bearer {}", request.token))
                .header("Content-Type", "application/json")
                .body(Body::from(body))
                .map_err(bad)?;
            api_router(app).oneshot(http).await.map_err(internal)?
        };
        send_response(&mut send, response).await
    }

    fn complete(
        &self,
        pairing: &pairing::Pairing,
        peer: &str,
        request: PairRequest,
    ) -> Result<Value> {
        if request.version != 1 || request.ticket.len() > 128 {
            return Err(bad("Invalid pairing request"));
        }
        let mut ticket = self.tickets.lock().unwrap();
        if !ticket.as_ref().is_some_and(|ticket| {
            ticket.expires > pairing::now() && ticket.hash == pairing::digest(&request.ticket)
        }) {
            return Err((
                StatusCode::UNAUTHORIZED,
                "二维码已过期或已使用，请在 Mac 上重新生成".into(),
            ));
        }
        let enrollment = pairing.enroll(request.name, Some(peer.to_owned()))?;
        *ticket = None;
        Ok(enrollment)
    }

    pub fn revoke(&self, peer: &str) {
        let connections: Vec<_> = self
            .connections
            .lock()
            .unwrap()
            .values()
            .filter(|(id, _)| id == peer)
            .map(|(_, conn)| conn.clone())
            .collect();
        // Let the request revoking its own device finish before closing streams.
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(250)).await;
            for connection in connections {
                connection.close(1u32.into(), b"Device revoked");
            }
        });
    }
    pub async fn shutdown(&self) {
        if let Some(endpoint) = self.endpoint.lock().await.take() {
            endpoint.close().await;
        }
    }
}

fn validate_request(request: &ApiRequest, peer: &str, pairing: &pairing::Pairing) -> Result<()> {
    if request.version != 1
        || request.length > MAX_FILE
        || request.path.len() > 8192
        || request.token.len() > 128
    {
        return Err(bad("Invalid or oversized request"));
    }
    if !pairing.valid_peer(&request.token, peer) {
        return Err((
            StatusCode::UNAUTHORIZED,
            "Device identity or credential rejected".into(),
        ));
    }
    if !request.path.starts_with("/v1/")
        || request.path.starts_with("/v1/pair/")
        || request.path.starts_with("/v1/iroh/pair/")
        || request.path.contains(['\r', '\n', '#'])
        || !["GET", "POST", "PUT", "DELETE"].contains(&request.method.as_str())
    {
        return Err(bad("Unsupported API request"));
    }
    Ok(())
}

async fn read_packet(recv: &mut iroh::endpoint::RecvStream, limit: usize) -> Result<Vec<u8>> {
    let mut size = [0; 4];
    recv.read_exact(&mut size).await.map_err(bad)?;
    let size = u32::from_be_bytes(size) as usize;
    if size == 0 || size > limit {
        return Err(bad("Invalid packet length"));
    }
    let mut bytes = vec![0; size];
    recv.read_exact(&mut bytes).await.map_err(bad)?;
    Ok(bytes)
}
async fn write_packet(send: &mut iroh::endpoint::SendStream, bytes: &[u8]) -> Result<()> {
    send.write_all(&(bytes.len() as u32).to_be_bytes())
        .await
        .map_err(internal)?;
    send.write_all(bytes).await.map_err(internal)
}
async fn send_response(
    send: &mut iroh::endpoint::SendStream,
    response: axum::response::Response,
) -> Result<()> {
    write_packet(
        send,
        &serde_json::to_vec(&json!({"status":response.status().as_u16()})).map_err(internal)?,
    )
    .await?;
    let mut body = response.into_body();
    while let Some(frame) = body.frame().await {
        if let Ok(bytes) = frame.map_err(internal)?.into_data() {
            for chunk in bytes.chunks(CHUNK_LIMIT) {
                tokio::time::timeout(TIMEOUT, write_packet(send, chunk))
                    .await
                    .map_err(internal)??;
            }
        }
    }
    send.write_all(&0u32.to_be_bytes())
        .await
        .map_err(internal)?;
    send.finish().map_err(internal)
}

pub async fn issue(State(app): State<Shared>, headers: HeaderMap) -> Result<Json<PairCode>> {
    if headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        != Some(&format!("Bearer {}", app.token))
    {
        return Err((StatusCode::FORBIDDEN, "Local administrator required".into()));
    }
    let endpoint = app.iroh.start(app.clone()).await?;
    // Starting via an explicit local pairing command enables future service launches.
    let mut config = app.config.lock().await;
    if !config
        .iroh
        .as_ref()
        .is_some_and(|settings| settings.enabled)
    {
        let mut next = config.clone();
        next.iroh.get_or_insert_with(Settings::default).enabled = true;
        next.revision = next
            .revision
            .checked_add(1)
            .ok_or_else(|| internal("Revision overflow"))?;
        pairing::private_write(
            &app.config_path,
            &serde_json::to_vec_pretty(&next).map_err(internal)?,
        )
        .map_err(internal)?;
        *config = next;
    }
    let relay_urls = config
        .iroh
        .as_ref()
        .and_then(|settings| settings.relay_urls.clone());
    drop(config);
    // A bounded wait lets relay/direct-address discovery settle without hanging
    // forever on offline networks. The identity remains usable for later lookup.
    let _ = tokio::time::timeout(Duration::from_secs(5), endpoint.online()).await;
    let addr = endpoint.addr();
    let mut relay_url = None;
    let mut addresses = Vec::new();
    for address in &addr.addrs {
        match address {
            iroh::TransportAddr::Relay(url) => relay_url = Some(url.to_string()),
            iroh::TransportAddr::Ip(socket) => addresses.push(socket.to_string()),
            _ => {}
        }
    }
    let ticket = pairing::secret();
    let expires = pairing::now() + 300;
    *app.iroh.tickets.lock().unwrap() = Some(Ticket {
        hash: pairing::digest(&ticket),
        expires,
    });
    let name = std::env::var("AGENTMUX_NAME").unwrap_or_else(|_| "My Mac".into());
    Ok(Json(PairCode {
        version: 2,
        transport: "iroh".into(),
        name,
        endpoint_id: addr.id.to_string(),
        relay_url,
        addresses,
        relay_urls,
        ticket,
        expires,
    }))
}

pub async fn status(State(app): State<Shared>, headers: HeaderMap) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let endpoint = app.iroh.endpoint.lock().await;
    Ok(Json(
        json!({"enabled":endpoint.is_some(),"endpoint_id":endpoint.as_ref().map(|endpoint|endpoint.id().to_string())}),
    ))
}

pub async fn pair_cli(
    token: &str,
    directory: &FsPath,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let response = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(20))
        .build()?
        .post(format!(
            "http://127.0.0.1:{}/v1/iroh/pair/issue",
            api_port()
        ))
        .bearer_auth(token)
        .send()
        .await?;
    if !response.status().is_success() {
        return Err(format!("Cannot create pairing code: {}", response.text().await?).into());
    }
    let code: PairCode = response.json().await?;
    let payload = serde_json::to_string(&code)?;
    let qr = qrcode::QrCode::new(payload.as_bytes())?;
    pairing::private_write(
        &directory.join("pair-iroh.svg"),
        qr.render::<qrcode::render::svg::Color>()
            .min_dimensions(600, 600)
            .build()
            .as_bytes(),
    )?;
    pairing::private_write(&directory.join("pair-iroh.json"), payload.as_bytes())?;
    println!(
        "Scan this code in AgentMux → Connect Mac → Scan QR. Expires in 5 minutes. Keep it private.\n{}",
        qr.render::<qrcode::render::unicode::Dense1x2>()
            .quiet_zone(true)
            .build()
    );
    println!("QR image: {}", directory.join("pair-iroh.svg").display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn local_pairing_http_client_has_an_explicit_tls_provider() {
        // iroh enables reqwest's no-provider TLS feature transitively. The local
        // pairing CLI must still construct its HTTP client without panicking.
        assert!(reqwest::Client::builder().no_proxy().build().is_ok());
    }

    #[test]
    fn ticket_is_short_lived_one_use_and_only_consumed_after_valid_enrollment() {
        let directory = tempfile::tempdir().unwrap();
        let pairing = pairing::Pairing::load(directory.path().into()).unwrap();
        let manager = Manager::new(directory.path().into());
        let secret = pairing::secret();
        let request = |ticket: &str, name: &str| PairRequest {
            version: 1,
            ticket: ticket.into(),
            name: name.into(),
        };
        *manager.tickets.lock().unwrap() = Some(Ticket {
            hash: pairing::digest(&secret),
            expires: pairing::now() + 300,
        });
        assert!(
            manager
                .complete(&pairing, "phone", request("wrong", "phone"))
                .is_err()
        );
        assert!(
            manager
                .complete(&pairing, "phone", request(&secret, " "))
                .is_err()
        );
        let enrolled = manager
            .complete(&pairing, "phone", request(&secret, "phone"))
            .unwrap();
        let token = enrolled["token"].as_str().unwrap();
        assert!(pairing.valid_peer(token, "phone"));
        assert!(
            manager
                .complete(&pairing, "another", request(&secret, "phone"))
                .is_err()
        );
        *manager.tickets.lock().unwrap() = Some(Ticket {
            hash: pairing::digest(&secret),
            expires: pairing::now() - 1,
        });
        assert!(
            manager
                .complete(&pairing, "phone", request(&secret, "phone"))
                .is_err()
        );
    }

    #[test]
    fn api_enforces_peer_binding_limits_and_local_pairing_boundary() {
        let directory = tempfile::tempdir().unwrap();
        let pairing = pairing::Pairing::load(directory.path().into()).unwrap();
        let enrolled = pairing.enroll("phone".into(), Some("peer".into())).unwrap();
        let mut request = ApiRequest {
            version: 1,
            method: "GET".into(),
            path: "/v1/settings".into(),
            token: enrolled["token"].as_str().unwrap().into(),
            length: 0,
        };
        assert!(validate_request(&request, "peer", &pairing).is_ok());
        assert!(validate_request(&request, "other", &pairing).is_err());
        for path in [
            "/v1/pair/issue",
            "/v1/iroh/pair/issue",
            "http://localhost/v1/settings",
            "/v1/settings\r\nInjected: yes",
        ] {
            request.path = path.into();
            assert!(validate_request(&request, "peer", &pairing).is_err());
        }
        request.path = "/v1/file".into();
        request.method = "PUT".into();
        request.length = MAX_FILE + 1;
        assert!(validate_request(&request, "peer", &pairing).is_err());
        let legacy: Settings = serde_json::from_str("{}").unwrap();
        assert!(!legacy.enabled);
        assert!(legacy.relay_urls.is_none());
    }
}
