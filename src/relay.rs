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
#[cfg(test)]
fn editor_ready(provider: &str, screen: &str, cursor: usize) -> bool {
    tmux_ui::Frame::parse(screen, if provider == "pi" { 0 } else { 2 }, cursor, true)
        .editor_ready(provider)
}
async fn ready(app: &App, session: &tmux_agents::Session) -> Result<bool> {
    Ok(tmux_ui::capture(app, &session.id)
        .await?
        .editor_ready(&session.command))
}
pub async fn terminal_controls(app: &App, session: &tmux_agents::Session) -> Result<Value> {
    let frame = tmux_ui::capture(app, &session.id).await?;
    Ok(
        json!({"commands":tmux_ui::commands(&session.command),"interaction":frame.menu(&session.command,session.agent_pid),"ready":frame.editor_ready(&session.command)}),
    )
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
    if let Some(mut snapshot) = pi_bridge::snapshot(&session).await? {
        let controls = terminal_controls(&app, &session).await?;
        if !controls["interaction"].is_null() {
            snapshot["interaction"] = controls["interaction"].clone();
            snapshot["capabilities"]["message"] = json!(false);
        }
        return Ok(Json(snapshot));
    }
    let relay = state(&app, &session).await;
    let mut state = relay.lock().await;
    scan(&session, &mut state).await?;
    let selected = state
        .selected
        .as_ref()
        .and_then(|id| state.conversations.iter().find(|c| &c.id == id));
    let mut history_error = None;
    let messages = if let Some(conversation) = selected {
        let path = conversation.path.clone();
        let provider = session.command.clone();
        match tokio::task::spawn_blocking(move || transcripts::read(&provider, &path))
            .await
            .map_err(internal)?
        {
            Ok(messages) => messages,
            Err(_) => {
                history_error = Some("历史记录暂不可读，交互仍连接当前窗口。");
                vec![]
            }
        }
    } else {
        vec![]
    };
    let controls = terminal_controls(&app, &session).await?;
    let ready = controls["ready"] == true;
    let notice = if !controls["interaction"].is_null() {
        "Agent 等待你的选择。先选择一项，再确认执行。"
    } else if selected.is_none() {
        "已连接原来的 Agent；可直接发送消息和命令，也可选择记录查看历史。"
    } else if ready {
        "已连接原来的 Agent；消息和命令发送到当前窗口。"
    } else {
        "Agent 正在工作、显示对话框或 Mac 输入框已有草稿；暂不发送新消息。"
    };
    Ok(Json(
        json!({"messages":messages,"models":[],"commands":controls["commands"],"interaction":controls["interaction"],"model":"","busy":false,"alive":true,"approvals":[],"error":history_error,"revision":0,
        "agent_pid":state.pid,"conversations":state.conversations,"conversation_id":state.selected,
        "capabilities":{"message":ready,"abort":true,"models":false,"approvals":false},"notice":notice,"source":"tmux"}),
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
    #[serde(default)]
    menu_id: String,
    #[serde(default)]
    choice: Option<usize>,
    #[serde(default)]
    control_id: String,
    #[serde(default)]
    approved: bool,
    #[serde(default)]
    route: Option<String>,
    #[serde(default)]
    attachments: Vec<String>,
    #[serde(skip_deserializing, default)]
    uploaded_files: Vec<attachments::Attachment>,
}
pub async fn action(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(mut request): Json<Action>,
) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let session = tmux_agents::find(&app, &id).await?;
    if session.agent_pid != request.agent_pid {
        return Err(conflict(
            "Agent process changed. Reopen this window before sending.",
        ));
    }
    if request.action == "message" {
        (request.text, request.uploaded_files) =
            attachments::prepare(&app, &request.text, &request.attachments).await?;
    } else if !request.attachments.is_empty() {
        return Err(bad("Only messages accept attachments"));
    }
    if request.route.as_deref() != Some("tmux")
        && !request.action.starts_with("menu_")
        && let Some(response) =
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
        "menu_select" | "menu_confirm" | "menu_cancel" | "menu_action" | "menu_search" => {
            let frame = tmux_ui::capture(&app, &id).await?;
            let menu = frame
                .menu(&session.command, session.agent_pid)
                .ok_or_else(|| conflict("菜单已结束，请刷新当前会话。"))?;
            if menu.id != request.menu_id {
                return Err(conflict("Mac 上的菜单已变化，请确认最新选项后重试。"));
            }
            let current_process = tmux_agents::find(&app, &id).await?;
            if current_process.agent_pid != request.agent_pid {
                return Err(conflict("Agent process changed; reopen the conversation"));
            }
            if request.action == "menu_search" {
                if !menu.searchable
                    || request.text.len() > 256
                    || request.text.chars().any(char::is_control)
                {
                    return Err(bad("当前交互没有可编辑的搜索框，或搜索内容无效"));
                }
                tmux(&app, &["send-keys", "-t", &id, "C-a", "C-k"]).await?;
                if !request.text.is_empty() {
                    tmux(&app, &["send-keys", "-t", &id, "-l", &request.text]).await?;
                }
            } else if request.action == "menu_action" {
                let key = interactions::executable(&menu, &request.control_id)?;
                tmux(&app, &["send-keys", "-t", &id, &key]).await?;
            } else if request.action == "menu_select" {
                let target = request.choice.ok_or_else(|| bad("请选择菜单选项"))?;
                if target >= menu.options.len() {
                    return Err(bad("Invalid menu option"));
                }
                let current = menu
                    .options
                    .iter()
                    .position(|c| c.selected)
                    .ok_or_else(|| conflict("菜单当前选项未知"))?;
                let key = if target > current { "Down" } else { "Up" };
                if target != current {
                    let mut keys = vec!["send-keys", "-t", &id];
                    keys.extend(std::iter::repeat_n(key, target.abs_diff(current)));
                    tmux(&app, &keys).await?;
                }
            } else {
                tmux(
                    &app,
                    &[
                        "send-keys",
                        "-t",
                        &id,
                        if request.action == "menu_confirm" {
                            "Enter"
                        } else {
                            "Escape"
                        },
                    ],
                )
                .await?;
            }
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
            return Err(bad("Unsupported operation for this tmux Agent"));
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
