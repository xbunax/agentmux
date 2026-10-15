//! Native provider plugins advertise private loopback bridges, including non-tmux sessions.
use crate::*;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::os::unix::fs::PermissionsExt;

#[derive(Clone, Deserialize)]
struct Manifest {
    version: u32,
    provider: String,
    id: String,
    pid: u32,
    #[serde(default)]
    agent_pid: Option<u32>,
    cwd: PathBuf,
    port: u16,
    token: String,
    #[serde(default)]
    tmux_pane: Option<String>,
}
fn directory() -> PathBuf {
    std::env::var_os("AGENTMUX_BRIDGE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join("Library/Application Support/AgentMux/bridges")
        })
}
fn key(manifest: &Manifest) -> String {
    format!(
        "{:x}",
        Sha256::digest(format!(
            "{}:{}:{}",
            manifest.provider, manifest.id, manifest.pid
        ))
    )
}
fn valid(manifest: &Manifest) -> bool {
    manifest.version == 2
        && ["codex", "claude", "pi"].contains(&manifest.provider.as_str())
        && !manifest.id.is_empty()
        && manifest.id.len() <= 256
        && manifest.pid > 1
        && manifest.cwd.is_absolute()
        && manifest.port > 0
        && manifest.token.len() == 64
        && manifest.token.bytes().all(|c| c.is_ascii_hexdigit())
}
async fn manifests() -> Vec<Manifest> {
    let Ok(mut entries) = tokio::fs::read_dir(directory()).await else {
        return vec![];
    };
    let mut values = Vec::new();
    let mut count = 0;
    while let Ok(Some(entry)) = entries.next_entry().await {
        count += 1;
        if count > 512 {
            break;
        }
        let Ok(metadata) = entry.metadata().await else {
            continue;
        };
        if !metadata.is_file()
            || metadata.len() > 65536
            || metadata.permissions().mode() & 0o077 != 0
        {
            continue;
        }
        let Ok(bytes) = tokio::fs::read(entry.path()).await else {
            continue;
        };
        if let Ok(manifest) = serde_json::from_slice::<Manifest>(&bytes)
            && valid(&manifest)
        {
            values.push(manifest);
        }
    }
    values
}
async fn find(id: &str) -> Result<Manifest> {
    if id.len() != 64 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(bad("Invalid plugin session"));
    }
    manifests()
        .await
        .into_iter()
        .find(|m| key(m) == id)
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                "插件连接已结束，请刷新会话列表。".into(),
            )
        })
}
async fn request(manifest: &Manifest, action: Option<Value>) -> Result<Value> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(16))
        .build()
        .map_err(internal)?;
    let url = format!(
        "http://127.0.0.1:{}/{}",
        manifest.port,
        if action.is_some() {
            "actions"
        } else {
            "snapshot"
        }
    );
    let builder = if let Some(value) = action {
        client.post(url).json(&value)
    } else {
        client.get(url)
    };
    let mut response = builder
        .bearer_auth(&manifest.token)
        .send()
        .await
        .map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "插件连接暂不可用，请检查 Mac 上的 Agent 插件。".into(),
            )
        })?;
    let status = response.status();
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(internal)? {
        if bytes.len() + chunk.len() > 8 * 1024 * 1024 {
            return Err(internal("Plugin response too large"));
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|_| internal("Invalid plugin response"))?;
    if !status.is_success() {
        return Err((
            status,
            value["error"].as_str().unwrap_or("插件操作失败").into(),
        ));
    }
    Ok(value)
}
pub async fn list(State(app): State<Shared>, headers: HeaderMap) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let values = manifests().await;
    // Bound concurrency so one stale bridge does not serialize every session behind its timeout.
    let mut tasks = tokio::task::JoinSet::new();
    let mut sessions = Vec::new();
    for batch in values.chunks(8) {
        for manifest in batch.iter().cloned() {
            tasks.spawn(async move {
                let probe=tokio::time::timeout(std::time::Duration::from_secs(2),request(&manifest,None)).await.ok()?.ok()?;
                if probe["alive"]==false || probe["bridge_id"]!=manifest.id || probe["bridge_pid"].as_u64()!=Some(manifest.pid.into()) {return None;}
                Some(json!({"id":key(&manifest),"name":format!("{} · {}",manifest.provider,manifest.cwd.file_name().unwrap_or_default().to_string_lossy()),"directory":manifest.cwd,"command":manifest.provider,"mode":"plugin","agent_pid":manifest.pid,"native_agent_pid":manifest.agent_pid,"native_pane_id":manifest.tmux_pane}))
            });
        }
        while let Some(value) = tasks.join_next().await {
            if let Ok(Some(session)) = value {
                sessions.push(session);
            }
        }
    }
    if sessions.iter().any(|s| s["native_pane_id"].is_string()) {
        let panes = tmux_agents::discover(&app).await.unwrap_or_default();
        for session in &mut sessions {
            let verified = panes.iter().any(|pane| {
                session["native_pane_id"] == pane.id
                    && session["native_agent_pid"].as_u64() == Some(pane.agent_pid.into())
                    && session["command"] == pane.command
            });
            if !verified {
                session["native_pane_id"] = Value::Null;
            }
        }
    }
    sessions.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    Ok(Json(json!(sessions)))
}
pub async fn snapshot(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let manifest = find(&id).await?;
    let mut value = request(&manifest, None).await?;
    if value["bridge_id"] != manifest.id
        || value["bridge_pid"].as_u64() != Some(manifest.pid.into())
    {
        return Err(bad("Plugin identity changed"));
    }
    if manifest.provider == "pi"
        && let Some(entries) = value["entries"].as_array()
    {
        value["messages"] =
            serde_json::to_value(transcripts::parse("pi", entries)).map_err(internal)?;
    }
    if let Some(path) = value["transcript_path"].as_str() {
        let path = PathBuf::from(path);
        let provider = manifest.provider.clone();
        if path.is_absolute() {
            let messages = tokio::task::spawn_blocking(move || transcripts::read(&provider, &path))
                .await
                .map_err(internal)?;
            if let Ok(messages) = messages {
                let mut history = serde_json::to_value(messages)
                    .map_err(internal)?
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                if let Some(live) = value["messages"].as_array() {
                    for message in live {
                        if !history.iter().any(|old| {
                            old["id"] == message["id"]
                                || (old["role"] == message["role"]
                                    && old["text"] == message["text"])
                        }) {
                            history.push(message.clone());
                        }
                    }
                }
                value["messages"] = json!(history);
            }
        }
    }
    if let Some(pane) = linked_pane(&app, &manifest).await {
        let controls = relay::terminal_controls(&app, &pane).await?;
        let mut commands = value["commands"].as_array().cloned().unwrap_or_default();
        for command in controls["commands"].as_array().into_iter().flatten() {
            if !commands.iter().any(|c| c["name"] == command["name"]) {
                commands.push(command.clone());
            }
        }
        value["commands"] = json!(commands);
        if value["capabilities"]["abort"] == false {
            value["capabilities"]["abort"] = json!(true);
            value["abort_route"] = json!("tmux");
        }
        if !controls["interaction"].is_null() {
            value["interaction"] = controls["interaction"].clone();
            value["interaction"]["route"] = json!("tmux");
        }
    }
    if let Some(object) = value.as_object_mut() {
        object.remove("transcript_path");
    }
    value["agent_pid"] = json!(manifest.pid);
    Ok(Json(value))
}
pub async fn action(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(mut value): Json<Value>,
) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let manifest = find(&id).await?;
    if value["agent_pid"].as_u64() != Some(manifest.pid.into()) {
        return Err((
            StatusCode::CONFLICT,
            "插件进程已变化，请重新打开会话。".into(),
        ));
    }
    // Receipt IDs are the only upload references accepted from a remote client.
    if let Some(object) = value.as_object_mut() {
        object.remove("uploaded_files");
    }
    if value["route"] != "tmux" && value["action"] == "message" {
        let ids: Vec<String> =
            serde_json::from_value(value.get("attachments").cloned().unwrap_or(json!([])))
                .map_err(bad)?;
        let (text, files) =
            attachments::prepare(&app, value["text"].as_str().unwrap_or_default(), &ids).await?;
        value["text"] = json!(text);
        value["uploaded_files"] = attachments::files_json(&files);
    }
    if value["route"] == "tmux" {
        if ![
            "message",
            "menu_select",
            "menu_confirm",
            "menu_cancel",
            "abort",
        ]
        .contains(&value["action"].as_str().unwrap_or_default())
        {
            return Err(bad("Unsupported tmux action"));
        }
        let pane = linked_pane(&app, &manifest).await.ok_or_else(|| {
            (
                StatusCode::CONFLICT,
                "此插件未绑定到原来的 tmux 进程，不能转发窗口操作。".into(),
            )
        })?;
        let mut forwarded = value;
        forwarded["agent_pid"] = json!(pane.agent_pid);
        return relay::action(
            State(app),
            headers,
            Path(pane.id),
            Json(serde_json::from_value::<relay::Action>(forwarded).map_err(bad)?),
        )
        .await;
    }
    if !["message", "command", "model", "abort", "approval"]
        .contains(&value["action"].as_str().unwrap_or_default())
    {
        return Err(bad("Unsupported plugin action"));
    }
    Ok(Json(request(&manifest, Some(value)).await?))
}
async fn linked_pane(app: &App, manifest: &Manifest) -> Option<tmux_agents::Session> {
    let id = manifest.tmux_pane.as_ref()?;
    let pane = tmux_agents::find(app, id).await.ok()?;
    if Some(pane.agent_pid) == manifest.agent_pid && pane.command == manifest.provider {
        Some(pane)
    } else {
        None
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requires_private_native_loopback_identity_and_binds_ids_to_the_process() {
        let mut m = Manifest {
            version: 2,
            provider: "codex".into(),
            id: "session".into(),
            pid: 20,
            agent_pid: None,
            cwd: "/project".into(),
            port: 8000,
            token: "a".repeat(64),
            tmux_pane: None,
        };
        assert!(valid(&m));
        let original = key(&m);
        m.pid = 21;
        assert_ne!(key(&m), original);
        m.provider = "unknown".into();
        assert!(!valid(&m));
        m.provider = "claude".into();
        m.cwd = "relative".into();
        assert!(!valid(&m));
    }
}
