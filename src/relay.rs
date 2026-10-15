//! Keep existing interactive processes alive. Relay only to a verified, empty Agent editor.
use crate::*;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};
use tokio::io::AsyncWriteExt;

#[derive(Default)]
pub struct Manager {
    sessions: Mutex<HashMap<String, Arc<Mutex<Relay>>>>,
}
struct Relay {
    pid: u32,
    conversations: Vec<transcripts::Conversation>,
    scanned: Instant,
    selected: Option<String>,
    sent: HashMap<String, (String, bool)>,
}
async fn state(app: &App, session: &tmux_agents::Session) -> Arc<Mutex<Relay>> {
    let mut sessions = app.relay.sessions.lock().await;
    let key = format!("{}:{}", session.id, session.agent_pid);
    sessions
        .entry(key)
        .or_insert_with(|| {
            Arc::new(Mutex::new(Relay {
                pid: session.agent_pid,
                conversations: vec![],
                scanned: Instant::now() - Duration::from_secs(60),
                selected: None,
                sent: HashMap::new(),
            }))
        })
        .clone()
}
async fn scan(session: &tmux_agents::Session, state: &mut Relay) -> Result<()> {
    if state.scanned.elapsed() < Duration::from_secs(10) {
        return Ok(());
    }
    let provider = session.command.clone();
    let cwd = session.directory.clone();
    state.conversations =
        tokio::task::spawn_blocking(move || transcripts::candidates(&provider, &cwd))
            .await
            .map_err(internal)?;
    state.scanned = Instant::now();
    // Claude publishes a PID/session mapping. Do not guess by modification time or cwd alone.
    if state.selected.is_none() && session.command == "claude" {
        let directory = transcripts::home("CLAUDE_CONFIG_DIR", ".claude").join("sessions");
        if let Ok(mut entries) = tokio::fs::read_dir(directory).await {
            let mut count = 0;
            while let Ok(Some(entry)) = entries.next_entry().await {
                count += 1;
                if count > 1000 {
                    break;
                }
                let Ok(metadata) = entry.metadata().await else {
                    continue;
                };
                if !metadata.is_file() || metadata.len() > 65536 {
                    continue;
                }
                let Ok(bytes) = tokio::fs::read(entry.path()).await else {
                    continue;
                };
                let Ok(info) = serde_json::from_slice::<Value>(&bytes) else {
                    continue;
                };
                if info["pid"].as_u64() != Some(session.agent_pid.into())
                    || info["cwd"].as_str().map(FsPath::new) != Some(&session.directory)
                {
                    continue;
                }
                let Some(id) = info["sessionId"].as_str() else {
                    continue;
                };
                state.selected = state
                    .conversations
                    .iter()
                    .find(|c| c.path.file_stem().is_some_and(|s| s == id))
                    .map(|c| c.id.clone());
            }
        }
    }
    Ok(())
}
fn conflict(message: &str) -> Error {
    (StatusCode::CONFLICT, message.into())
}
pub fn editor_ready(provider: &str, screen: &str, cursor: usize) -> bool {
    let lines: Vec<_> = screen.lines().collect();
    let Some(line) = lines.get(cursor) else {
        return false;
    };
    match provider {
        "codex" => line.trim() == "›",
        "claude" => line.trim() == "❯",
        "pi" => {
            fn border(s: &str) -> bool {
                let s = s.trim();
                s.chars().count() >= 8 && s.chars().all(|c| c == '─')
            }
            line.trim().is_empty()
                && cursor > 0
                && lines.get(cursor - 1).is_some_and(|s| border(s))
                && lines.get(cursor + 1).is_some_and(|s| border(s))
        }
        _ => false,
    }
}
async fn ready(app: &App, session: &tmux_agents::Session) -> Result<bool> {
    let cursor = tmux(
        app,
        &["display-message", "-p", "-t", &session.id, "#{cursor_y}"],
    )
    .await?;
    let screen = tmux(app, &["capture-pane", "-p", "-t", &session.id]).await?;
    Ok(cursor
        .trim()
        .parse()
        .is_ok_and(|row| editor_ready(&session.command, &screen, row)))
}
fn valid_text(text: &str) -> bool {
    !text.trim().is_empty()
        && text.len() <= 65536
        && !text
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\t')
}
pub async fn snapshot(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let session = tmux_agents::find(&app, &id).await?;
    if let Some(snapshot) = pi_bridge::snapshot(&session).await? {
        return Ok(Json(snapshot));
    }
    let relay = state(&app, &session).await;
    let mut state = relay.lock().await;
    scan(&session, &mut state).await?;
    let selected = state
        .selected
        .as_ref()
        .and_then(|id| state.conversations.iter().find(|c| &c.id == id));
    let messages = if let Some(conversation) = selected {
        let path = conversation.path.clone();
        let provider = session.command.clone();
        tokio::task::spawn_blocking(move || transcripts::read(&provider, &path))
            .await
            .map_err(internal)?
            .map_err(internal)?
    } else {
        vec![]
    };
    let ready = ready(&app, &session).await?;
    let notice = if selected.is_none() {
        "请选择此窗口当前使用的对话记录；不会按最近修改时间自动猜测。"
    } else if ready {
        "已连接原有 Agent。审批与模型设置请在 Mac 上操作，或新建原生会话。"
    } else {
        "Agent 正在工作、显示对话框或 Mac 输入框已有草稿；暂不发送新消息。"
    };
    Ok(Json(
        json!({"messages":messages,"models":[],"commands":[],"model":"","busy":false,"alive":true,"approvals":[],"error":null,"revision":0,
        "agent_pid":state.pid,"conversations":state.conversations,"conversation_id":state.selected,
        "capabilities":{"message":ready && selected.is_some(),"abort":true,"models":false,"approvals":false},"notice":notice,"source":"tmux"}),
    ))
}
#[derive(Deserialize, Serialize)]
pub struct Action {
    action: String,
    agent_pid: u32,
    #[serde(default)]
    text: String,
    #[serde(default)]
    request_id: String,
    #[serde(default)]
    conversation_id: String,
    #[serde(default)]
    model: String,
    #[serde(default)]
    provider: String,
}
pub async fn action(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(request): Json<Action>,
) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let session = tmux_agents::find(&app, &id).await?;
    if session.agent_pid != request.agent_pid {
        return Err(conflict(
            "Agent process changed. Reopen this window before sending.",
        ));
    }
    if let Some(response) =
        pi_bridge::action(&session, serde_json::to_value(&request).map_err(internal)?).await?
    {
        return Ok(Json(response));
    }
    let relay = state(&app, &session).await;
    let mut state = relay.lock().await;
    scan(&session, &mut state).await?;
    match request.action.as_str() {
        "select_conversation" => {
            if !state
                .conversations
                .iter()
                .any(|c| c.id == request.conversation_id)
            {
                return Err(bad(
                    "Conversation is not associated with this Agent project",
                ));
            }
            state.selected = Some(request.conversation_id);
        }
        "message" => {
            if !valid_text(&request.text)
                || request.request_id.is_empty()
                || request.request_id.len() > 128
            {
                return Err(bad("Valid text and request_id are required"));
            }
            if let Some((text, accepted)) = state.sent.get(&request.request_id) {
                if text != &request.text {
                    return Err(conflict("Message ID was already used for different text"));
                }
                if !accepted {
                    return Err(conflict(
                        "Previous delivery is uncertain. Inspect the Mac conversation before retrying.",
                    ));
                }
                return Ok(Json(json!({"accepted":true})));
            }
            if state.sent.len() >= 1024 {
                return Err(conflict(
                    "Relay message limit reached; reconnect the daemon after inspecting the conversation",
                ));
            }
            if !state
                .selected
                .as_ref()
                .is_some_and(|id| state.conversations.iter().any(|c| &c.id == id))
            {
                return Err(conflict(
                    "Select this window's current conversation before sending",
                ));
            }
            if !ready(&app, &session).await? {
                return Err(conflict(
                    "Agent editor is not empty and ready. Finish the current task or dialog on the Mac.",
                ));
            }
            let current = tmux_agents::find(&app, &id).await?;
            if current.agent_pid != request.agent_pid {
                return Err(conflict("Agent process changed; message was not sent"));
            }
            let buffer = format!("agentmux-{}", uuid::Uuid::new_v4().simple());
            let mut child = Command::new(&app.tmux)
                .args(["load-buffer", "-b", &buffer, "-"])
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true)
                .spawn()
                .map_err(internal)?;
            let mut stdin = child
                .stdin
                .take()
                .ok_or_else(|| internal("No tmux buffer input"))?;
            stdin
                .write_all(request.text.as_bytes())
                .await
                .map_err(internal)?;
            drop(stdin);
            let exit = tokio::time::timeout(Duration::from_secs(5), child.wait())
                .await
                .map_err(internal)?
                .map_err(internal)?;
            if !exit.success() {
                return Err(internal("Unable to prepare message buffer"));
            }
            let current = tmux_agents::find(&app, &id).await;
            let unchanged = current
                .as_ref()
                .is_ok_and(|s| s.agent_pid == request.agent_pid);
            if !unchanged || !ready(&app, &session).await.unwrap_or(false) {
                let _ = tmux(&app, &["delete-buffer", "-b", &buffer]).await;
                return Err(conflict(
                    "Agent or editor changed while preparing the message; nothing was pasted",
                ));
            }
            // Persist uncertainty before the first input byte. Never automatically repeat an ambiguous send.
            state
                .sent
                .insert(request.request_id.clone(), (request.text.clone(), false));
            let result = tmux(
                &app,
                &[
                    "paste-buffer",
                    "-p",
                    "-d",
                    "-b",
                    &buffer,
                    "-t",
                    &id,
                    ";",
                    "send-keys",
                    "-t",
                    &id,
                    "Enter",
                ],
            )
            .await;
            if result.is_err() {
                let _ = tmux(&app, &["delete-buffer", "-b", &buffer]).await;
            }
            result?;
            state.sent.insert(request.request_id, (request.text, true));
        }
        "abort" => {
            tmux(&app, &["send-keys", "-t", &id, "Escape"]).await?;
        }
        _ => {
            return Err(bad(
                "This existing TUI supports messages and Escape only; use a native session for models and approvals",
            ));
        }
    }
    Ok(Json(json!({"accepted":true})))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requires_an_empty_known_editor_and_rejects_drafts_and_menus() {
        assert!(editor_ready("codex", "answer\n› \nfooter", 1));
        assert!(!editor_ready("codex", "› existing Mac draft", 0));
        assert!(!editor_ready("claude", "❯ 1. Yes\n2. No", 0));
        assert!(editor_ready("claude", "answer\n❯ \nfooter", 1));
        assert!(editor_ready("pi", "────────────\n  \n────────────", 1));
        assert!(!editor_ready(
            "pi",
            "────────────\ndraft\n\n────────────",
            2
        ));
        assert!(!editor_ready("pi", "┌──────────┐\n\n└──────────┘", 1));
    }
    #[test]
    fn rejects_terminal_control_injection_but_allows_multiline_messages() {
        assert!(valid_text("hello\nsecond line\tend"));
        for text in ["\u{1b}[A", "hello\rcommand", "\0", "\u{3}", "   "] {
            assert!(!valid_text(text));
        }
    }
}
