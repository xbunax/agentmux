mod agents;
mod attachments;
mod config;
mod discovery;
mod interactions;
mod iroh_transport;
mod pairing;
mod pi_bridge;
mod plugin_bridge;
mod relay;
mod terminal;
mod tmux_agents;
mod tmux_ui;
mod transcripts;

use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{HeaderMap, StatusCode},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path as FsPath, PathBuf},
    sync::Arc,
};
use tokio::{process::Command, sync::Mutex};

type Error = (StatusCode, String);
type Result<T> = std::result::Result<T, Error>;
fn bad(message: impl ToString) -> Error {
    (StatusCode::BAD_REQUEST, message.to_string())
}
fn internal(message: impl ToString) -> Error {
    (StatusCode::INTERNAL_SERVER_ERROR, message.to_string())
}
fn api_port() -> u16 {
    std::env::var("AGENTMUX_API_PORT")
        .unwrap_or_else(|_| "9847".into())
        .parse::<std::num::NonZeroU16>()
        .expect("AGENTMUX_API_PORT must be between 1 and 65535")
        .get()
}

#[derive(Clone, Serialize, Deserialize)]
struct Config {
    revision: u64,
    roots: Vec<PathBuf>,
    default_directory: PathBuf,
    agents: Agents,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    iroh: Option<iroh_transport::Settings>,
}
#[derive(Clone, Serialize, Deserialize)]
struct Agents {
    codex: String,
    claude: String,
    pi: String,
}
struct App {
    config: Mutex<Config>,
    ceiling: Vec<PathBuf>,
    config_path: PathBuf,
    token: String,
    tmux: String,
    pairing: Arc<pairing::Pairing>,
    managed: agents::Manager,
    relay: relay::Manager,
    terminal: terminal::Manager,
    attachments: attachments::Store,
    iroh: Arc<iroh_transport::Manager>,
}
type Shared = Arc<App>;
fn authorize(headers: &HeaderMap, app: &App) -> Result<()> {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default();
    if token != app.token && !app.pairing.valid_device(token) {
        return Err((StatusCode::UNAUTHORIZED, "Authentication required".into()));
    }
    Ok(())
}
fn confined(path: &FsPath, roots: &[PathBuf]) -> Result<PathBuf> {
    let canonical = path.canonicalize().map_err(bad)?;
    if !roots.iter().any(|root| canonical.starts_with(root)) {
        return Err((
            StatusCode::FORBIDDEN,
            "Outside authorized directories".into(),
        ));
    }
    Ok(canonical)
}
async fn tmux(app: &App, args: &[&str]) -> Result<String> {
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        Command::new(&app.tmux)
            .kill_on_drop(true)
            .args(args)
            .output(),
    )
    .await
    .map_err(internal)?
    .map_err(internal)?;
    if !output.status.success() {
        return Err(bad(String::from_utf8_lossy(&output.stderr)));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}
async fn settings(State(app): State<Shared>, headers: HeaderMap) -> Result<Json<Config>> {
    authorize(&headers, &app)?;
    Ok(Json(app.config.lock().await.clone()))
}
async fn update_settings(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(mut next): Json<Config>,
) -> Result<Json<Config>> {
    authorize(&headers, &app)?;
    let mut current = app.config.lock().await;
    if current.revision != next.revision {
        return Err((
            StatusCode::CONFLICT,
            "Configuration changed; reload first".into(),
        ));
    }
    if next.roots.is_empty() {
        return Err(bad("At least one root is required"));
    }
    next.roots = next
        .roots
        .iter()
        .map(|r| confined(r, &app.ceiling))
        .collect::<Result<_>>()?;
    for root in &next.roots {
        if !root.is_dir() {
            return Err(bad("Root must be a directory"));
        }
    }
    next.default_directory = confined(&next.default_directory, &next.roots)?;
    if !next.default_directory.is_dir() {
        return Err(bad("Default directory must be a directory"));
    }
    // Executable selection is deliberately local-only: changing it remotely permits arbitrary code execution.
    if next.agents.codex != current.agents.codex
        || next.agents.claude != current.agents.claude
        || next.agents.pi != current.agents.pi
    {
        return Err(bad("Agent executables can only be configured locally"));
    }
    if next.iroh.is_some() && next.iroh != current.iroh {
        return Err(bad("iroh settings can only be configured locally"));
    }
    next.iroh = current.iroh.clone();
    next.revision = current
        .revision
        .checked_add(1)
        .ok_or_else(|| bad("Revision overflow"))?;
    let bytes = serde_json::to_vec_pretty(&next).map_err(internal)?;
    let temporary = app.config_path.with_extension("tmp");
    tokio::fs::write(&temporary, bytes)
        .await
        .map_err(internal)?;
    tokio::fs::rename(&temporary, &app.config_path)
        .await
        .map_err(internal)?;
    *current = next.clone();
    Ok(Json(next))
}
async fn sessions(
    State(app): State<Shared>,
    headers: HeaderMap,
) -> Result<Json<Vec<tmux_agents::Session>>> {
    authorize(&headers, &app)?;
    Ok(Json(tmux_agents::discover(&app).await?))
}
async fn check_pane(app: &App, id: &str) -> Result<()> {
    tmux_agents::find(app, id).await?;
    Ok(())
}
async fn output(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<String> {
    authorize(&headers, &app)?;
    check_pane(&app, &id).await?;
    tmux(&app, &["capture-pane", "-p", "-t", &id, "-S", "-1000"]).await
}
// Legacy endpoints carried no stream generation or process identity. Keeping
// them writable would bypass the terminal workbench's stale-target protection.
async fn retired_terminal_write(
    State(app): State<Shared>,
    headers: HeaderMap,
) -> Result<StatusCode> {
    authorize(&headers, &app)?;
    Err((
        StatusCode::GONE,
        "Use a confirmed /v1/terminal stream generation for terminal input".into(),
    ))
}
#[derive(Deserialize)]
struct Create {
    agent: String,
    directory: PathBuf,
}
async fn create(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(request): Json<Create>,
) -> Result<Json<serde_json::Value>> {
    authorize(&headers, &app)?;
    let config = app.config.lock().await;
    let directory = confined(&request.directory, &config.roots)?;
    if !directory.is_dir() {
        return Err(bad("Not a directory"));
    }
    let executable = match request.agent.as_str() {
        "codex" => &config.agents.codex,
        "claude" => &config.agents.claude,
        "pi" => &config.agents.pi,
        _ => return Err(bad("Unknown agent")),
    }
    .clone();
    drop(config);
    let name = format!("agentmux-{}", uuid::Uuid::new_v4().simple());
    // tmux treats multiple command arguments as a direct exec, not a shell command.
    let pane = tmux(
        &app,
        &[
            "new-session",
            "-d",
            "-P",
            "-F",
            "#{pane_id}",
            "-s",
            &name,
            "-c",
            directory
                .to_str()
                .ok_or_else(|| bad("Invalid path encoding"))?,
            "--",
            "/usr/bin/env",
            &executable,
        ],
    )
    .await?;
    Ok(Json(
        serde_json::json!({"id": pane.trim(), "mode": "terminal"}),
    ))
}
#[derive(Deserialize)]
struct FileQuery {
    path: PathBuf,
}
#[derive(Serialize)]
struct Entry {
    name: String,
    directory: bool,
    size: u64,
}
async fn files(
    State(app): State<Shared>,
    headers: HeaderMap,
    Query(query): Query<FileQuery>,
) -> Result<Json<Vec<Entry>>> {
    authorize(&headers, &app)?;
    let path = confined(&query.path, &app.config.lock().await.roots)?;
    let mut directory = tokio::fs::read_dir(path).await.map_err(bad)?;
    let mut entries = vec![];
    while let Some(entry) = directory.next_entry().await.map_err(bad)? {
        let metadata = entry.metadata().await.map_err(bad)?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        entries.push(Entry {
            name: entry.file_name().to_string_lossy().into(),
            directory: metadata.is_dir(),
            size: metadata.len(),
        });
        if entries.len() >= 1000 {
            break;
        }
    }
    Ok(Json(entries))
}
const MAX_FILE: usize = 8 * 1024 * 1024;
fn file_capability(path: &FsPath, roots: &[PathBuf]) -> Result<(cap_std::fs::Dir, PathBuf)> {
    let parent = path.parent().ok_or_else(|| bad("Missing parent"))?;
    let parent = confined(parent, roots)?;
    let root = roots
        .iter()
        .find(|r| parent.starts_with(r))
        .ok_or_else(|| bad("Outside roots"))?;
    let name = path.file_name().ok_or_else(|| bad("Missing filename"))?;
    let relative = parent.strip_prefix(root).map_err(bad)?.join(name);
    let dir =
        cap_std::fs::Dir::open_ambient_dir(root, cap_std::ambient_authority()).map_err(bad)?;
    Ok((dir, relative))
}
async fn download(
    State(app): State<Shared>,
    headers: HeaderMap,
    Query(query): Query<FileQuery>,
) -> Result<Bytes> {
    authorize(&headers, &app)?;
    let (dir, relative) = file_capability(&query.path, &app.config.lock().await.roots)?;
    tokio::task::spawn_blocking(move || {
        use std::io::Read;
        let file = dir.open(relative).map_err(bad)?;
        let metadata = file.metadata().map_err(bad)?;
        if !metadata.is_file() || metadata.len() > MAX_FILE as u64 {
            return Err(bad("Only regular files up to 8 MiB are supported"));
        }
        let mut bytes = Vec::new();
        file.take(MAX_FILE as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(bad)?;
        if bytes.len() > MAX_FILE {
            return Err(bad("File too large"));
        }
        Ok(Bytes::from(bytes))
    })
    .await
    .map_err(internal)?
}
async fn upload(
    State(app): State<Shared>,
    headers: HeaderMap,
    Query(query): Query<FileQuery>,
    body: Bytes,
) -> Result<StatusCode> {
    authorize(&headers, &app)?;
    if body.len() > MAX_FILE {
        return Err(bad("File exceeds 8 MiB"));
    }
    let (dir, relative) = file_capability(&query.path, &app.config.lock().await.roots)?;
    tokio::task::spawn_blocking(move || {
        use std::io::Write;
        let mut options = cap_std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        let mut file = dir.open_with(&relative, &options).map_err(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                (StatusCode::CONFLICT, "File already exists".into())
            } else {
                bad(e)
            }
        })?;
        if let Err(error) = file.write_all(&body).and_then(|_| file.sync_all()) {
            let _ = dir.remove_file(relative);
            return Err(internal(error));
        }
        Ok(StatusCode::CREATED)
    })
    .await
    .map_err(internal)?
}
#[tokio::main]
async fn main() -> std::result::Result<(), Box<dyn std::error::Error>> {
    interactions::initialize()?;
    if std::env::args().nth(1).as_deref() == Some("connect") {
        return discovery::connect_cli(std::env::args().nth(2).unwrap_or("SSH device".into()))
            .await;
    }
    let paths = config::Paths::from_env()?;
    let state_dir = paths.state;
    let pairing = pairing::Pairing::load(state_dir.clone())?;
    let token_path = state_dir.join("admin.token");
    let token = match std::env::var("AGENTMUX_TOKEN") {
        Ok(token) => token,
        Err(_) if token_path.exists() => std::fs::read_to_string(&token_path)?,
        Err(_) => {
            let token = format!(
                "{}{}",
                uuid::Uuid::new_v4().simple(),
                uuid::Uuid::new_v4().simple()
            );
            pairing::private_write(&token_path, token.as_bytes())?;
            token
        }
    };
    if std::env::args().nth(1).as_deref() == Some("pair") {
        let args: Vec<String> = std::env::args().skip(2).collect();
        if args == ["--transport", "iroh"] {
            return iroh_transport::pair_cli(&token, &state_dir).await;
        }
        if args.first().is_some_and(|arg| arg.starts_with('-')) {
            return Err("Usage: agentmuxd pair [host] | agentmuxd pair --transport iroh".into());
        }
        let host = std::env::args().nth(2).unwrap_or_else(|| {
            let socket = std::net::UdpSocket::bind("0.0.0.0:0").expect("Local UDP socket");
            if socket.connect("1.1.1.1:80").is_ok() {
                socket
                    .local_addr()
                    .map(|a| a.ip().to_string())
                    .unwrap_or("127.0.0.1".into())
            } else {
                "127.0.0.1".into()
            }
        });
        return pairing::pair_cli(&token, &state_dir, host).await;
    }
    if token.len() < 32 {
        return Err("AGENTMUX_TOKEN must contain at least 32 characters".into());
    }
    let config_path = paths.config;
    let config = config::load_or_create(&config_path)?;
    let ceiling: Vec<PathBuf> = config
        .roots
        .iter()
        .map(|r| r.canonicalize())
        .collect::<std::io::Result<_>>()?;
    if ceiling.is_empty() || ceiling.iter().any(|r| !r.is_dir()) {
        return Err("Invalid roots".into());
    }
    confined(&config.default_directory, &ceiling).map_err(|(_, e)| e)?;
    let config = Config {
        roots: ceiling.clone(),
        ..config
    };
    let app = Arc::new(App {
        config: Mutex::new(config),
        ceiling,
        config_path,
        token,
        tmux: std::env::var("AGENTMUX_TMUX").unwrap_or("tmux".into()),
        pairing: pairing.clone(),
        managed: agents::Manager::default(),
        relay: relay::Manager::default(),
        terminal: terminal::Manager::with_journal(&state_dir),
        attachments: attachments::Store::temporary(&state_dir)?,
        iroh: Arc::new(iroh_transport::Manager::new(state_dir)),
    });
    terminal::recover_sizes(&app).await;
    let router = api_router(app.clone());
    let listener =
        tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, api_port())).await?;
    discovery::publish(&app)?;
    let iroh_enabled = app
        .config
        .lock()
        .await
        .iroh
        .as_ref()
        .is_some_and(|settings| settings.enabled);
    if iroh_enabled {
        app.iroh
            .start(app.clone())
            .await
            .map_err(|(_, message)| message)?;
    }
    if std::env::var_os("AGENTMUX_SSH_DISABLED").is_none() {
        tokio::spawn(async move {
            if let Err(error) = pairing::serve(pairing).await {
                eprintln!("SSH transport stopped: {error}");
            }
        });
        eprintln!("Optional QR SSH on port 9848: `agentmuxd pair [Mac-IP-or-Tailscale-host]`.");
    }
    eprintln!("agentmuxd API on 127.0.0.1:{}", api_port());
    eprintln!(
        "Pair over iroh with `agentmuxd pair --transport iroh`, or connect using SSH in the iPhone app."
    );
    axum::serve(listener, router)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    app.iroh.shutdown().await;
    Ok(())
}

fn api_router(app: Shared) -> Router {
    Router::new()
        .route("/v1/iroh/pair/issue", post(iroh_transport::issue))
        .route("/v1/iroh/status", get(iroh_transport::status))
        .route("/v1/pair/issue", post(pairing::issue))
        .route("/v1/pair/complete", post(pairing::complete))
        .route("/v1/devices", get(pairing::devices).post(pairing::enroll))
        .route("/v1/devices/{id}", axum::routing::delete(pairing::revoke))
        .route("/v1/plugins", get(plugin_bridge::list))
        .route(
            "/v1/attachments/{id}",
            get(attachments::download).put(attachments::upload),
        )
        .route("/v1/plugins/{id}/chat", get(plugin_bridge::snapshot))
        .route("/v1/plugins/{id}/actions", post(plugin_bridge::action))
        .route("/v1/managed", get(agents::list).post(agents::create))
        .route("/v1/managed/{id}", get(agents::snapshot))
        .route("/v1/managed/{id}/actions", post(agents::action))
        .route("/v1/settings", get(settings).put(update_settings))
        .route("/v1/terminal/panes", get(terminal::list))
        .route("/v1/terminal/panes/{id}/open", post(terminal::open))
        .route(
            "/v1/terminal/streams/{id}",
            get(terminal::stream).delete(terminal::close),
        )
        .route("/v1/terminal/streams/{id}/input", post(terminal::input))
        .route("/v1/sessions", get(sessions).post(create))
        .route("/v1/sessions/{id}/chat", get(relay::snapshot))
        .route("/v1/sessions/{id}/actions", post(relay::action))
        .route("/v1/sessions/{id}/output", get(output))
        .route("/v1/sessions/{id}/input", post(retired_terminal_write))
        .route("/v1/sessions/{id}/interrupt", post(retired_terminal_write))
        .route("/v1/files", get(files))
        .route("/v1/file", get(download).put(upload))
        .layer(DefaultBodyLimit::max(MAX_FILE))
        .with_state(app)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn boundaries() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let roots = vec![root.path().canonicalize().unwrap()];
        assert!(confined(root.path(), &roots).is_ok());
        assert!(confined(outside.path(), &roots).is_err());
        std::os::unix::fs::symlink(outside.path(), root.path().join("escape")).unwrap();
        assert!(confined(&root.path().join("escape"), &roots).is_err());
        assert!(confined(&root.path().join("missing"), &roots).is_err());
    }
    #[test]
    fn auth_requires_exact_token() {
        let app = App {
            config: Mutex::new(Config {
                revision: 0,
                roots: vec![],
                default_directory: PathBuf::new(),
                agents: Agents {
                    codex: "codex".into(),
                    claude: "claude".into(),
                    pi: "pi".into(),
                },
                iroh: None,
            }),
            ceiling: vec![],
            config_path: PathBuf::new(),
            token: "secret".into(),
            tmux: "tmux".into(),
            pairing: pairing::Pairing::load(tempfile::tempdir().unwrap().keep()).unwrap(),
            managed: agents::Manager::default(),
            relay: relay::Manager::default(),
            terminal: terminal::Manager::default(),
            attachments: attachments::Store::new(PathBuf::new()),
            iroh: Arc::new(iroh_transport::Manager::new(PathBuf::new())),
        };
        let mut headers = HeaderMap::new();
        assert!(authorize(&headers, &app).is_err());
        headers.insert("authorization", "Bearer secret".parse().unwrap());
        assert!(authorize(&headers, &app).is_ok());
    }
}
