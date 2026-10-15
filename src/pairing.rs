//! Restricted SSH transport: no shells, no arbitrary forwarding, per-device credentials.
use crate::*;
use russh::server::{self, Server as _};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    sync::Mutex as StdMutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn secret() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}
fn digest(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn host_identity_persists_and_credentials_are_hashed() {
        let directory = tempfile::tempdir().unwrap();
        let first = Pairing::load(directory.path().to_path_buf()).unwrap();
        let second = Pairing::load(directory.path().to_path_buf()).unwrap();
        assert_eq!(first.public_key, second.public_key);
        assert_eq!(
            std::fs::metadata(directory.path().join("ssh_host_ed25519"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(!first.authenticate("wrong"));
        let token = secret();
        first.devices.lock().unwrap().push(Device {
            id: "test".into(),
            name: "test".into(),
            hash: digest(&token),
            created: now(),
        });
        assert!(first.valid_device(&token));
        assert!(!first.valid_device("wrong"));
    }
    #[test]
    fn pairing_tickets_expire_and_authenticate_once() {
        let directory = tempfile::tempdir().unwrap();
        let pairing = Pairing::load(directory.path().to_path_buf()).unwrap();
        let token = secret();
        pairing.tickets.lock().unwrap().insert(
            digest(&token),
            Ticket {
                hash: digest(&token),
                expires: now() + 300,
                authenticated: false,
            },
        );
        assert!(pairing.authenticate(&token));
        assert!(!pairing.authenticate(&token));
        let expired = secret();
        pairing.tickets.lock().unwrap().insert(
            digest(&expired),
            Ticket {
                hash: digest(&expired),
                expires: now() - 1,
                authenticated: false,
            },
        );
        assert!(!pairing.authenticate(&expired));
    }
    #[test]
    fn ssh_enrollment_persists_only_a_hash_and_rejects_invalid_names() {
        let directory = tempfile::tempdir().unwrap();
        let pairing = Pairing::load(directory.path().to_path_buf()).unwrap();
        let enrolled = pairing.enroll_device("SSH phone".into()).unwrap();
        let token = enrolled["token"].as_str().unwrap();
        assert!(pairing.valid_device(token));
        let path = directory.path().join("devices.json");
        let saved = std::fs::read_to_string(&path).unwrap();
        assert!(!saved.contains(token));
        assert!(saved.contains(&digest(token)));
        assert!(pairing.enroll_device(" ".into()).is_err());
        assert!(pairing.enroll_device("x".repeat(101)).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), saved);
        let reloaded = Pairing::load(directory.path().to_path_buf()).unwrap();
        assert!(reloaded.valid_device(token));
    }
}
#[derive(Serialize, Deserialize, Clone)]
pub struct Device {
    pub id: String,
    pub name: String,
    hash: String,
    pub created: u64,
}
struct Ticket {
    hash: String,
    expires: u64,
    authenticated: bool,
}
pub struct Pairing {
    pub directory: PathBuf,
    pub public_key: String,
    pub key: russh::keys::PrivateKey,
    devices: StdMutex<Vec<Device>>,
    tickets: StdMutex<HashMap<String, Ticket>>,
}
pub fn private_write(path: &FsPath, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(temp, path)
}
impl Pairing {
    pub fn load(directory: PathBuf) -> std::result::Result<Arc<Self>, Box<dyn std::error::Error>> {
        std::fs::create_dir_all(&directory)?;
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;
        let path = directory.join("ssh_host_ed25519");
        let key = if path.exists() {
            russh::keys::load_secret_key(&path, None)?
        } else {
            let key =
                russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519)?;
            private_write(
                &path,
                key.to_openssh(russh::keys::ssh_key::LineEnding::LF)?
                    .as_bytes(),
            )?;
            key
        };
        let devices = if directory.join("devices.json").exists() {
            serde_json::from_slice(&std::fs::read(directory.join("devices.json"))?)?
        } else {
            vec![]
        };
        Ok(Arc::new(Self {
            public_key: key.public_key().to_openssh()?,
            key,
            directory,
            devices: StdMutex::new(devices),
            tickets: StdMutex::new(HashMap::new()),
        }))
    }
    pub fn valid_device(&self, token: &str) -> bool {
        let hash = digest(token);
        self.devices.lock().unwrap().iter().any(|d| d.hash == hash)
    }
    fn enroll_device(&self, name: String) -> Result<serde_json::Value> {
        if name.len() > 100 || name.trim().is_empty() {
            return Err(bad("Device name must contain 1–100 bytes"));
        }
        let token = secret();
        let device = Device {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            hash: digest(&token),
            created: now(),
        };
        let mut devices = self.devices.lock().unwrap();
        let mut next = devices.clone();
        next.push(device.clone());
        private_write(
            &self.directory.join("devices.json"),
            &serde_json::to_vec(&next).map_err(internal)?,
        )
        .map_err(internal)?;
        *devices = next;
        Ok(serde_json::json!({"token": token, "device_id": device.id}))
    }
    fn authenticate(&self, password: &str) -> bool {
        if self.valid_device(password) {
            return true;
        }
        let hash = digest(password);
        let mut tickets = self.tickets.lock().unwrap();
        tickets.retain(|_, t| t.expires > now());
        if let Some(ticket) = tickets
            .values_mut()
            .find(|t| t.hash == hash && !t.authenticated)
        {
            ticket.authenticated = true;
            ticket.expires = now() + 60;
            return true;
        }
        false
    }
}
#[derive(Serialize, Deserialize)]
pub struct PairCode {
    pub version: u8,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub host_key: String,
    pub ticket: String,
    pub expires: u64,
}
#[derive(Deserialize)]
pub struct PairRequest {
    host: String,
}
pub async fn issue(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(request): Json<PairRequest>,
) -> Result<Json<PairCode>> {
    // Only the local administrator token may enroll devices.
    if headers.get("authorization").and_then(|h| h.to_str().ok())
        != Some(&format!("Bearer {}", app.token))
    {
        return Err((StatusCode::FORBIDDEN, "Local administrator required".into()));
    }
    if request.host.is_empty()
        || request.host.len() > 253
        || request.host.contains(['/', '@', '\n'])
    {
        return Err(bad("Invalid host"));
    }
    let secret = secret();
    let expires = now() + 300;
    let mut tickets = app.pairing.tickets.lock().unwrap();
    tickets.clear(); // Generating a new code invalidates older outstanding codes.
    tickets.insert(
        digest(&secret),
        Ticket {
            hash: digest(&secret),
            expires,
            authenticated: false,
        },
    );
    Ok(Json(PairCode {
        version: 1,
        host: request.host,
        port: 9848,
        username: "agentmux".into(),
        host_key: app.pairing.public_key.clone(),
        ticket: secret,
        expires,
    }))
}
#[derive(Deserialize)]
pub struct Complete {
    ticket: String,
    name: String,
}
pub async fn complete(
    State(app): State<Shared>,
    Json(request): Json<Complete>,
) -> Result<Json<serde_json::Value>> {
    if request.name.len() > 100 {
        return Err(bad("Device name too long"));
    }
    let mut tickets = app.pairing.tickets.lock().unwrap();
    let hash = digest(&request.ticket);
    let valid = tickets
        .get(&hash)
        .is_some_and(|t| t.authenticated && t.expires > now());
    if !valid {
        return Err((
            StatusCode::UNAUTHORIZED,
            "Pairing expired or already used; generate a new QR code".into(),
        ));
    }
    let result = app.pairing.enroll_device(request.name)?;
    tickets.remove(&hash);
    Ok(Json(result))
}
#[derive(Deserialize)]
pub struct Enrollment {
    name: String,
}
pub async fn enroll(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(request): Json<Enrollment>,
) -> Result<Json<serde_json::Value>> {
    if headers.get("authorization").and_then(|h| h.to_str().ok())
        != Some(&format!("Bearer {}", app.token))
    {
        return Err((StatusCode::FORBIDDEN, "Local administrator required".into()));
    }
    Ok(Json(app.pairing.enroll_device(request.name)?))
}
pub async fn devices(
    State(app): State<Shared>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>> {
    authorize(&headers, &app)?;
    Ok(Json(serde_json::Value::Array(
        app.pairing
            .devices
            .lock()
            .unwrap()
            .iter()
            .map(|d| serde_json::json!({"id":d.id,"name":d.name,"created":d.created}))
            .collect(),
    )))
}
pub async fn revoke(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode> {
    authorize(&headers, &app)?;
    let mut devices = app.pairing.devices.lock().unwrap();
    let next: Vec<_> = devices.iter().filter(|d| d.id != id).cloned().collect();
    private_write(
        &app.pairing.directory.join("devices.json"),
        &serde_json::to_vec(&next).map_err(internal)?,
    )
    .map_err(internal)?;
    *devices = next;
    Ok(StatusCode::NO_CONTENT)
}
#[derive(Clone)]
struct Ssh {
    pairing: Arc<Pairing>,
}
impl server::Server for Ssh {
    type Handler = Self;
    fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self {
        self.clone()
    }
    fn handle_session_error(&mut self, error: russh::Error) {
        eprintln!("SSH session error: {error}");
    }
}
impl server::Handler for Ssh {
    type Error = russh::Error;
    async fn auth_password(
        &mut self,
        user: &str,
        password: &str,
    ) -> std::result::Result<server::Auth, Self::Error> {
        Ok(
            if user == "agentmux" && self.pairing.authenticate(password) {
                server::Auth::Accept
            } else {
                server::Auth::reject()
            },
        )
    }
    async fn channel_open_direct_tcpip(
        &mut self,
        channel: russh::Channel<server::Msg>,
        host: &str,
        port: u32,
        _: &str,
        _: u32,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> std::result::Result<(), Self::Error> {
        if host != "127.0.0.1" || port != 9847 {
            reply
                .reject(russh::ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return Ok(());
        }
        match tokio::net::TcpStream::connect("127.0.0.1:9847").await {
            Ok(mut socket) => {
                reply.accept().await;
                tokio::spawn(async move {
                    let mut channel = channel;
                    if let Err(error) = forward_api(&mut channel, &mut socket).await {
                        eprintln!("SSH API forwarding failed: {error}");
                    }
                    let _ = channel.close().await;
                });
            }
            Err(_) => {
                reply.reject(russh::ChannelOpenFailure::ConnectFailed).await;
            }
        }
        Ok(())
    }
}
async fn forward_api(
    channel: &mut russh::Channel<server::Msg>,
    socket: &mut tokio::net::TcpStream,
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut buffer = vec![0; 32 * 1024];
    let mut response_open = true;
    loop {
        tokio::select! {
            response = socket.read(&mut buffer), if response_open => {
                let count = response?;
                if count == 0 {
                    response_open = false;
                    // Preserve the read half until the client has consumed the response
                    // and closes its SSH channel. TCP EOF is only a half-close.
                    channel.eof().await.map_err(std::io::Error::other)?;
                } else {
                    channel.data(&buffer[..count]).await.map_err(std::io::Error::other)?;
                }
            }
            message = channel.wait() => match message {
                Some(russh::ChannelMsg::Data { data }) => socket.write_all(&data).await?,
                Some(russh::ChannelMsg::Eof) => socket.shutdown().await?,
                Some(russh::ChannelMsg::Close) | None => return Ok(()),
                _ => {}
            }
        }
    }
}
pub async fn serve(pairing: Arc<Pairing>) -> std::io::Result<()> {
    let config = server::Config {
        keys: vec![pairing.key.clone()],
        auth_rejection_time: Duration::from_secs(2),
        inactivity_timeout: Some(Duration::from_secs(300)),
        ..Default::default()
    };
    let address = std::env::var("AGENTMUX_SSH_BIND").unwrap_or("0.0.0.0:9848".into());
    let listener = tokio::net::TcpListener::bind(address).await?;
    Ssh { pairing }
        .run_on_socket(Arc::new(config), &listener)
        .await
}
pub async fn pair_cli(
    token: &str,
    directory: &FsPath,
    host: String,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(10))
        .build()?;
    let response = client
        .post("http://127.0.0.1:9847/v1/pair/issue")
        .bearer_auth(token)
        .json(&serde_json::json!({"host":host}))
        .send()
        .await?
        .error_for_status()?;
    let code: PairCode = response.json().await?;
    let payload = serde_json::to_string(&code)?;
    let qr = qrcode::QrCode::new(payload.as_bytes())?;
    let svg = qr
        .render::<qrcode::render::svg::Color>()
        .min_dimensions(600, 600)
        .build();
    let output = directory.join("pair.svg");
    private_write(&output, svg.as_bytes())?;
    private_write(&directory.join("pair.json"), payload.as_bytes())?;
    println!(
        "Scan {} in AgentMux. Expires in 5 minutes; keep it private.",
        output.display()
    );
    // QR itself is intended for a local terminal, not a daemon log.
    println!(
        "{}",
        qr.render::<qrcode::render::unicode::Dense1x2>()
            .quiet_zone(true)
            .build()
    );
    Ok(())
}
