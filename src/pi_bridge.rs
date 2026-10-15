//! An explicitly loaded Pi extension exposes the SAME live process via its SDK.
use crate::*;
use serde_json::{Value, json};
#[derive(Deserialize)]
struct Bridge {
    version: u32,
    pid: u32,
    port: u16,
    token: String,
    cwd: PathBuf,
}
async fn bridge(session: &tmux_agents::Session) -> Result<Option<Bridge>> {
    if session.command != "pi" {
        return Ok(None);
    }
    let directory = std::env::var_os("AGENTMUX_BRIDGE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join("Library/Application Support/AgentMux/bridges")
        });
    let path = directory.join(format!("pi-{}.json", session.agent_pid));
    let metadata = match tokio::fs::metadata(&path).await {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(internal(e)),
    };
    use std::os::unix::fs::PermissionsExt;
    if !metadata.is_file() || metadata.len() > 65536 || metadata.permissions().mode() & 0o077 != 0 {
        return Err(bad("Pi bridge manifest must be a private file"));
    }
    let bridge: Bridge = serde_json::from_slice(&tokio::fs::read(path).await.map_err(internal)?)
        .map_err(|_| bad("Invalid Pi bridge manifest"))?;
    if bridge.version != 1
        || bridge.pid != session.agent_pid
        || bridge.cwd != session.directory
        || bridge.port == 0
        || bridge.token.len() != 64
    {
        return Err(bad("Pi bridge does not match the live Agent"));
    }
    Ok(Some(bridge))
}
async fn request(bridge: Bridge, action: Option<Value>) -> Result<Value> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(internal)?;
    let url = format!(
        "http://127.0.0.1:{}/{}",
        bridge.port,
        if action.is_some() {
            "actions"
        } else {
            "snapshot"
        }
    );
    let builder = if let Some(action) = action {
        client.post(url).json(&action)
    } else {
        client.get(url)
    };
    let mut response = builder
        .bearer_auth(bridge.token)
        .send()
        .await
        .map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "Pi bridge unavailable; reload the extension on the Mac".into(),
            )
        })?;
    let status = response.status();
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(internal)? {
        if bytes.len() + chunk.len() > 8 * 1024 * 1024 {
            return Err(internal("Pi bridge snapshot too large"));
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|_| internal("Invalid Pi bridge response"))?;
    if !status.is_success() {
        return Err((
            StatusCode::from_u16(status.as_u16()).unwrap_or(StatusCode::BAD_GATEWAY),
            value["error"]
                .as_str()
                .unwrap_or("Pi bridge action failed")
                .into(),
        ));
    }
    Ok(value)
}
pub async fn snapshot(session: &tmux_agents::Session) -> Result<Option<Value>> {
    let Some(bridge) = bridge(session).await? else {
        return Ok(None);
    };
    let value = request(bridge, None).await?;
    if value["pid"].as_u64() != Some(session.agent_pid.into())
        || value["cwd"].as_str().map(FsPath::new) != Some(&session.directory)
    {
        return Err(bad("Pi bridge identity changed"));
    }
    let entries = value["entries"].as_array().cloned().unwrap_or_default();
    Ok(Some(
        json!({"messages":transcripts::parse("pi",&entries),"models":value["models"],"commands":[],"model":value["model"],"busy":value["busy"],"alive":true,"approvals":[],"error":null,"revision":0,
        "agent_pid":session.agent_pid,"source":"pi-extension","capabilities":{"message":value["can_send"],"abort":true,"models":true,"approvals":false},
        "notice":if value["waiting"]==true {"Pi 正等待 Mac 上的扩展对话框。"}else{"已通过 Pi 扩展连接原有会话。"}}),
    ))
}
pub async fn action(session: &tmux_agents::Session, value: Value) -> Result<Option<Value>> {
    let Some(bridge) = bridge(session).await? else {
        return Ok(None);
    };
    Ok(Some(request(bridge, Some(value)).await?))
}
