//! Private, per-user discovery for enrollment through an existing SSH login.

use crate::*;
use std::os::unix::fs::DirBuilderExt;

#[derive(Serialize, Deserialize)]
struct Service {
    version: u8,
    executable: PathBuf,
    admin_token: String,
}

fn path() -> std::io::Result<PathBuf> {
    if let Some(path) = std::env::var_os("AGENTMUX_DISCOVERY") {
        return Ok(path.into());
    }
    let home = std::env::var_os("HOME")
        .ok_or_else(|| std::io::Error::other("HOME is unavailable; set AGENTMUX_DISCOVERY"))?;
    Ok(PathBuf::from(home).join("Library/Application Support/AgentMux/service.json"))
}

pub fn publish(app: &App) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let path = path()?;
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)?;
    }
    pairing::private_write(
        &path,
        &serde_json::to_vec(&Service {
            version: 1,
            executable: std::env::current_exe()?,
            admin_token: app.token.clone(),
        })?,
    )?;
    Ok(())
}

pub async fn connect_cli(name: String) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let service: Service = serde_json::from_slice(&std::fs::read(path()?).map_err(|error| {
        std::io::Error::new(
            error.kind(),
            format!("AgentMux service not found; start agentmuxd on this Mac first: {error}"),
        )
    })?)?;
    if service.version != 1 {
        return Err("Unsupported AgentMux service version".into());
    }
    let response = reqwest::Client::builder()
        .no_proxy()
        .timeout(std::time::Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()?
        .post("http://127.0.0.1:9847/v1/devices")
        .bearer_auth(service.admin_token)
        .json(&serde_json::json!({"name": name}))
        .send()
        .await?
        .error_for_status()?;
    let mut result: serde_json::Value = response.json().await?;
    result["version"] = 1.into();
    result["api_port"] = 9847.into();
    // Only the new device credential is returned over SSH, never the administrator token.
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}
