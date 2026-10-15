//! Long-lived native JSONL adapters. Existing tmux panes remain terminal-only.
use crate::*;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::process::Stdio;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::ChildStdin,
    sync::oneshot,
};

#[derive(Default)]
pub struct Manager {
    pub sessions: Mutex<HashMap<String, Arc<Managed>>>,
}
#[derive(Serialize, Clone)]
pub struct ChatMessage {
    id: String,
    role: String,
    text: String,
}
#[derive(Serialize, Clone)]
pub struct Model {
    id: String,
    name: String,
    provider: String,
}
#[derive(Serialize, Clone)]
pub struct Slash {
    name: String,
    description: String,
}
#[derive(Serialize, Clone)]
pub struct Approval {
    id: String,
    title: String,
    detail: String,
    options: Vec<String>,
    kind: String,
}
#[derive(Serialize, Clone, Default)]
pub struct Snapshot {
    messages: Vec<ChatMessage>,
    models: Vec<Model>,
    commands: Vec<Slash>,
    model: String,
    busy: bool,
    alive: bool,
    approvals: Vec<Approval>,
    error: Option<String>,
    revision: u64,
}
pub struct Managed {
    pub id: String,
    pub agent: String,
    pub directory: PathBuf,
    stdin: Mutex<ChildStdin>,
    pending: Mutex<HashMap<String, oneshot::Sender<Value>>>,
    state: Mutex<Snapshot>,
    thread: Mutex<String>,
    turn: Mutex<String>,
    operations: Mutex<()>,
    approvals: Mutex<HashMap<String, Value>>,
    sent: Mutex<HashMap<String, (String, Value)>>,
}
impl Managed {
    async fn write(&self, value: Value) -> Result<()> {
        let mut input = self.stdin.lock().await;
        let mut bytes = serde_json::to_vec(&value).map_err(internal)?;
        bytes.push(b'\n');
        input.write_all(&bytes).await.map_err(internal)?;
        input.flush().await.map_err(internal)
    }
    async fn rpc(&self, name: &str, params: Value) -> Result<Value> {
        let id = uuid::Uuid::new_v4().to_string();
        let (send, receive) = oneshot::channel();
        self.pending.lock().await.insert(id.clone(), send);
        let value = match self.agent.as_str() {
            "pi" => {
                let mut value = params;
                value["type"] = json!(name);
                value["id"] = json!(id);
                value
            }
            "claude" => {
                let mut request = params;
                request["subtype"] = json!(name);
                json!({"type":"control_request","request_id":id,"request":request})
            }
            _ => json!({"id":id,"method":name,"params":params}),
        };
        if let Err(error) = self.write(value).await {
            self.pending.lock().await.remove(&id);
            return Err(error);
        }
        let result = tokio::time::timeout(std::time::Duration::from_secs(25), receive).await;
        self.pending.lock().await.remove(&id);
        let value = result
            .map_err(|_| {
                (
                    StatusCode::GATEWAY_TIMEOUT,
                    format!("Agent did not acknowledge {name}; inspect state before retrying"),
                )
            })?
            .map_err(internal)?;
        if value.get("error").is_some()
            || value.get("success") == Some(&json!(false))
            || value.pointer("/response/subtype") == Some(&json!("error"))
        {
            return Err(bad(value.to_string()));
        }
        Ok(match self.agent.as_str() {
            "pi" => value["data"].clone(),
            "claude" => value["response"]["response"].clone(),
            _ => value["result"].clone(),
        })
    }
    async fn initialize(&self) -> Result<()> {
        match self.agent.as_str() {
            "pi" => {
                let state = self.rpc("get_state", json!({})).await?;
                let models = self.rpc("get_available_models", json!({})).await?;
                let commands = self.rpc("get_commands", json!({})).await?;
                let mut s = self.state.lock().await;
                s.model = state["model"]["id"].as_str().unwrap_or_default().into();
                s.models = array(&models["models"])
                    .iter()
                    .map(|m| Model {
                        id: text(m, "id"),
                        name: text(m, "name"),
                        provider: text(m, "provider"),
                    })
                    .collect();
                s.commands = array(&commands["commands"])
                    .iter()
                    .map(|c| Slash {
                        name: text(c, "name"),
                        description: text(c, "description"),
                    })
                    .collect();
                s.commands.extend([
                    Slash {
                        name: "new".into(),
                        description: "开始新对话".into(),
                    },
                    Slash {
                        name: "compact".into(),
                        description: "压缩上下文（可能调用模型）".into(),
                    },
                ]);
            }
            "codex" => {
                self.rpc(
                    "initialize",
                    json!({"clientInfo":{"name":"agentmux","version":"0.2.0"}}),
                )
                .await?;
                self.write(json!({"method":"initialized"})).await?;
                let thread = self.rpc("thread/start", json!({"cwd": self.directory, "approvalPolicy":"on-request", "sandbox":"workspace-write"})).await?;
                *self.thread.lock().await = text(&thread["thread"], "id");
                let models = self.rpc("model/list", json!({})).await?;
                let mut s = self.state.lock().await;
                s.model = text(&thread, "model");
                s.models = array(&models["data"])
                    .iter()
                    .map(|m| Model {
                        id: text(m, "model"),
                        name: text(m, "displayName"),
                        provider: "".into(),
                    })
                    .collect();
                s.commands = vec![Slash {
                    name: "compact".into(),
                    description: "压缩当前线程上下文".into(),
                }];
            }
            "claude" => {
                let initialized = self
                    .rpc("initialize", json!({"hooks":{},"sdkMcpServers":[]}))
                    .await?;
                let mut s = self.state.lock().await;
                s.models = array(&initialized["models"])
                    .iter()
                    .map(|m| Model {
                        id: text(m, "value"),
                        name: text(m, "displayName"),
                        provider: "".into(),
                    })
                    .collect();
                s.commands = array(&initialized["commands"])
                    .iter()
                    .map(|c| Slash {
                        name: text(c, "name"),
                        description: text(c, "description"),
                    })
                    .collect();
            }
            _ => return Err(bad("Unknown adapter")),
        }
        self.state.lock().await.revision += 1;
        Ok(())
    }
    async fn record(&self, value: Value) {
        let response_id = if self.agent == "claude" {
            value.pointer("/response/request_id")
        } else {
            value.get("id")
        };
        let is_response = if self.agent == "pi" {
            value["type"] == "response"
        } else if self.agent == "claude" {
            value["type"] == "control_response"
        } else {
            value.get("method").is_none()
        };
        if is_response
            && let Some(id) = response_id.and_then(Value::as_str)
            && let Some(sender) = self.pending.lock().await.remove(id)
        {
            let _ = sender.send(value);
            return;
        }
        let kind = value["type"]
            .as_str()
            .or(value["method"].as_str())
            .unwrap_or("");
        let mut state = self.state.lock().await;
        state.revision += 1;
        match self.agent.as_str() {
            "pi" => match kind {
                "agent_start" => state.busy = true,
                "agent_settled" => state.busy = false,
                "message_start" if value["message"]["role"] == "assistant" => {
                    upsert(&mut state, "stream", "assistant", "".into(), false)
                }
                "message_update" if value["assistantMessageEvent"]["type"] == "text_delta" => {
                    upsert(
                        &mut state,
                        "stream",
                        "assistant",
                        text(&value["assistantMessageEvent"], "delta"),
                        true,
                    )
                }
                "message_end" if value["message"]["role"] == "assistant" => {
                    upsert(
                        &mut state,
                        "stream",
                        "assistant",
                        content(&value["message"]["content"]),
                        false,
                    );
                    if let Some(m) = state.messages.iter_mut().find(|m| m.id == "stream") {
                        m.id = uuid::Uuid::new_v4().to_string();
                    }
                    if let Some(error) = value["message"]["errorMessage"].as_str() {
                        state.error = Some(error.into());
                    }
                }
                "tool_execution_start" => upsert(
                    &mut state,
                    &text(&value, "toolCallId"),
                    "tool",
                    format!("{}\n{}", text(&value, "toolName"), value["args"]),
                    false,
                ),
                "tool_execution_end" => upsert(
                    &mut state,
                    &text(&value, "toolCallId"),
                    "tool",
                    format!(
                        "{}\n{}",
                        text(&value, "toolName"),
                        content(&value["result"]["content"])
                    ),
                    false,
                ),
                "extension_ui_request" => {
                    let method = text(&value, "method");
                    if ["confirm", "select", "input", "editor"].contains(&method.as_str()) {
                        let id = text(&value, "id");
                        state.approvals.push(Approval {
                            id: id.clone(),
                            title: text(&value, "title"),
                            detail: text(&value, "message"),
                            options: array(&value["options"])
                                .iter()
                                .filter_map(|v| v.as_str().map(String::from))
                                .collect(),
                            kind: method,
                        });
                        self.approvals.lock().await.insert(id, value.clone());
                    } else if method == "notify" {
                        upsert(
                            &mut state,
                            &text(&value, "id"),
                            "system",
                            text(&value, "message"),
                            false,
                        );
                    }
                }
                _ => {}
            },
            "claude" => match kind {
                "system" if value["subtype"] == "init" => {
                    state.model = text(&value, "model");
                }
                "stream_event" => {
                    let event = &value["event"];
                    if event["type"] == "message_start" {
                        upsert(&mut state, "stream", "assistant", "".into(), false);
                    }
                    if event["delta"]["type"] == "text_delta" {
                        upsert(
                            &mut state,
                            "stream",
                            "assistant",
                            text(&event["delta"], "text"),
                            true,
                        );
                    }
                }
                "assistant" => {
                    upsert(
                        &mut state,
                        "stream",
                        "assistant",
                        content(&value["message"]["content"]),
                        false,
                    );
                    if let Some(m) = state.messages.iter_mut().find(|m| m.id == "stream") {
                        m.id = uuid::Uuid::new_v4().to_string();
                    }
                }
                "user" => {
                    let result = content(&value["message"]["content"]);
                    if !result.is_empty() {
                        upsert(
                            &mut state,
                            &uuid::Uuid::new_v4().to_string(),
                            "tool",
                            result,
                            false,
                        );
                    }
                }
                "result" => {
                    state.busy = false;
                    if value["is_error"] == true {
                        state.error = Some(value.to_string());
                    }
                }
                "control_request" => {
                    let id = text(&value, "request_id");
                    let request = &value["request"];
                    state.approvals.push(Approval {
                        id: id.clone(),
                        title: text(request, "tool_name"),
                        detail: request["input"].to_string(),
                        options: vec![],
                        kind: "confirm".into(),
                    });
                    self.approvals.lock().await.insert(id, value.clone());
                }
                _ => {}
            },
            _ => {
                let params = &value["params"];
                match kind {
                    "turn/started" => {
                        state.busy = true;
                        *self.turn.lock().await = text(&params["turn"], "id");
                    }
                    "turn/completed" => {
                        state.busy = false;
                        if !params["turn"]["error"].is_null() {
                            state.error = Some(params["turn"]["error"].to_string());
                        }
                    }
                    "item/agentMessage/delta" => upsert(
                        &mut state,
                        &text(params, "itemId"),
                        "assistant",
                        text(params, "delta"),
                        true,
                    ),
                    "item/completed" => {
                        let item = &params["item"];
                        let id = text(item, "id");
                        if item["type"] == "agentMessage" {
                            upsert(&mut state, &id, "assistant", text(item, "text"), false);
                        } else if item["type"] != "userMessage" {
                            upsert(&mut state, &id, "tool", item.to_string(), false);
                        }
                    }
                    "error" => state.error = Some(params.to_string()),
                    _ => {
                        if let Some(id) = value.get("id") {
                            let key = id.to_string();
                            let supported = kind.ends_with("requestApproval");
                            state.approvals.push(Approval {
                                id: key.clone(),
                                title: kind.into(),
                                detail: params.to_string(),
                                options: vec![],
                                kind: if supported { "confirm" } else { "unsupported" }.into(),
                            });
                            self.approvals.lock().await.insert(key, value.clone());
                        }
                    }
                }
            }
        }
        let mut bytes: usize = state.messages.iter().map(|m| m.text.len()).sum();
        while state.messages.len() > 500 || (bytes > 4 * 1024 * 1024 && state.messages.len() > 1) {
            let removed = state.messages.remove(0);
            bytes = bytes.saturating_sub(removed.text.len());
        }
    }
}
fn array(value: &Value) -> &[Value] {
    value.as_array().map(Vec::as_slice).unwrap_or(&[])
}
fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().into()
}
fn content(value: &Value) -> String {
    if let Some(s) = value.as_str() {
        return s.into();
    }
    array(value)
        .iter()
        .map(|v| match v["type"].as_str() {
            Some("text") => text(v, "text"),
            Some("tool_use") => format!("🔧 {}\n{}", text(v, "name"), v["input"]),
            Some("tool_result") => content(&v["content"]),
            _ => String::new(),
        })
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}
fn upsert(state: &mut Snapshot, id: &str, role: &str, text: String, append: bool) {
    let text: String = text.chars().take(128 * 1024).collect();
    if let Some(message) = state.messages.iter_mut().find(|m| m.id == id) {
        if append {
            if message.text.len() < 128 * 1024 {
                message.text.push_str(&text);
            }
        } else {
            message.text = text;
        }
    } else {
        state.messages.push(ChatMessage {
            id: id.into(),
            role: role.into(),
            text,
        });
    }
}
async fn find(app: &App, id: &str) -> Result<Arc<Managed>> {
    let session = app
        .managed
        .sessions
        .lock()
        .await
        .get(id)
        .cloned()
        .ok_or_else(|| (StatusCode::NOT_FOUND, "Managed session not found".into()))?;
    confined(&session.directory, &app.config.lock().await.roots)?;
    Ok(session)
}
pub async fn create(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(request): Json<Create>,
) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let config = app.config.lock().await;
    let directory = confined(&request.directory, &config.roots)?;
    let executable = match request.agent.as_str() {
        "pi" => &config.agents.pi,
        "codex" => &config.agents.codex,
        "claude" => &config.agents.claude,
        _ => return Err(bad("Unknown agent")),
    }
    .clone();
    drop(config);
    let args: &[&str] = match request.agent.as_str() {
        "pi" => &["--mode", "rpc"],
        "claude" => &[
            "--print",
            "--verbose",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--include-partial-messages",
            "--permission-prompt-tool",
            "stdio",
        ],
        _ => &["app-server", "--stdio"],
    };
    let mut child = Command::new(executable)
        .args(args)
        .current_dir(&directory)
        .env_remove("AGENTMUX_TOKEN")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(bad)?;
    let stdin = child.stdin.take().ok_or_else(|| internal("No stdin"))?;
    let stdout = child.stdout.take().ok_or_else(|| internal("No stdout"))?;
    let stderr = child.stderr.take().ok_or_else(|| internal("No stderr"))?;
    let session = Arc::new(Managed {
        id: uuid::Uuid::new_v4().to_string(),
        agent: request.agent,
        directory,
        stdin: Mutex::new(stdin),
        pending: Mutex::new(HashMap::new()),
        state: Mutex::new(Snapshot {
            alive: true,
            ..Default::default()
        }),
        thread: Mutex::new(String::new()),
        turn: Mutex::new(String::new()),
        operations: Mutex::new(()),
        approvals: Mutex::new(HashMap::new()),
        sent: Mutex::new(HashMap::new()),
    });
    let reader = session.clone();
    let stdout_task = tokio::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Ok(value) = serde_json::from_str(&line) {
                reader.record(value).await;
            }
        }
    });
    let errors = session.clone();
    let stderr_task = tokio::spawn(async move {
        let mut lines = BufReader::new(stderr).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if !line.is_empty() {
                errors.state.lock().await.error = Some(line.chars().take(2000).collect());
            }
        }
    });
    if let Err(error) = session.initialize().await {
        let _ = child.kill().await;
        stdout_task.abort();
        stderr_task.abort();
        return Err(error);
    }
    let monitor = session.clone();
    tokio::spawn(async move {
        let status = child.wait().await;
        let _ = stdout_task.await;
        let _ = stderr_task.await;
        let mut state = monitor.state.lock().await;
        state.alive = false;
        state.busy = false;
        state.error = Some(format!("Agent exited: {status:?}"));
        monitor.pending.lock().await.clear();
    });
    let result = json!({"id":session.id,"mode":"structured"});
    app.managed
        .sessions
        .lock()
        .await
        .insert(session.id.clone(), session);
    Ok(Json(result))
}
pub async fn list(State(app): State<Shared>, headers: HeaderMap) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let sessions = app.managed.sessions.lock().await;
    let roots = app.config.lock().await.roots.clone();
    Ok(Json(Value::Array(sessions.values().filter(|s|confined(&s.directory,&roots).is_ok()).map(|s|json!({"id":s.id,"name":s.agent,"command":s.agent,"directory":s.directory,"mode":"structured"})).collect())))
}
pub async fn snapshot(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Snapshot>> {
    authorize(&headers, &app)?;
    let session = find(&app, &id).await?;
    Ok(Json(session.state.lock().await.clone()))
}
#[derive(Deserialize)]
pub struct Action {
    action: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    model: String,
    #[serde(default)]
    provider: String,
    #[serde(default)]
    request_id: String,
    #[serde(default)]
    approved: bool,
}
pub async fn action(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(request): Json<Action>,
) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let session = find(&app, &id).await?;
    let _operation = if ["message", "model", "command"].contains(&request.action.as_str()) {
        Some(session.operations.lock().await)
    } else {
        None
    };
    if !session.state.lock().await.alive {
        return Err(bad("Agent has exited"));
    }
    let response = match request.action.as_str() {
        "message" => {
            if request.text.len() > 65536
                || request.text.is_empty()
                || request.request_id.is_empty()
            {
                return Err(bad("Message text and request_id are required"));
            }
            if let Some((previous_text, previous)) =
                session.sent.lock().await.get(&request.request_id).cloned()
            {
                if previous_text != request.text {
                    return Err((
                        StatusCode::CONFLICT,
                        "Message ID was already used for different text".into(),
                    ));
                }
                if previous["accepted"] == "unknown" {
                    return Err((StatusCode::CONFLICT, "Previous send has an ambiguous outcome; inspect the conversation, do not resend blindly".into()));
                }
                return Ok(Json(previous));
            }
            {
                let mut state = session.state.lock().await;
                if state.busy {
                    return Err((StatusCode::CONFLICT, "Agent is busy".into()));
                }
                state.busy = true;
                state.error = None;
                upsert(
                    &mut state,
                    &request.request_id,
                    "user",
                    request.text.clone(),
                    false,
                );
            }
            // Mark before writing: an ambiguous timeout must never lead to automatic duplicate execution.
            session.sent.lock().await.insert(
                request.request_id.clone(),
                (request.text.clone(), json!({"accepted":"unknown"})),
            );
            let result=match session.agent.as_str() {
                "pi"=>session.rpc("prompt",json!({"message":request.text})).await,
                "claude"=>session.write(json!({"type":"user","message":{"role":"user","content":request.text},"parent_tool_use_id":null,"session_id":""})).await.map(|_|json!({})),
                _=>{
                    let thread=session.thread.lock().await.clone(); let model=session.state.lock().await.model.clone();
                    session.rpc("turn/start",json!({"threadId":thread,"model":model,"input":[{"type":"text","text":request.text}]})).await
                }
            };
            if let Err(error) = result {
                let mut s = session.state.lock().await;
                s.error = Some(error.1.clone());
                if error.0 != StatusCode::GATEWAY_TIMEOUT {
                    s.busy = false;
                }
                return Err(error);
            }
            let accepted = json!({"accepted":true});
            session
                .sent
                .lock()
                .await
                .insert(request.request_id, (request.text, accepted.clone()));
            accepted
        }
        "model" => {
            let state = session.state.lock().await;
            if state.busy {
                return Err((
                    StatusCode::CONFLICT,
                    "Wait for the current turn before changing model".into(),
                ));
            }
            if !state.models.iter().any(|m| {
                m.id == request.model && (session.agent != "pi" || m.provider == request.provider)
            }) {
                return Err(bad("Model was not advertised by this agent"));
            }
            drop(state);
            match session.agent.as_str() {
                "pi" => {
                    session
                        .rpc(
                            "set_model",
                            json!({"provider":request.provider,"modelId":request.model}),
                        )
                        .await?;
                }
                "claude" => {
                    session
                        .rpc("set_model", json!({"model":request.model}))
                        .await?;
                }
                _ => {} // Codex model override is applied and validated by turn/start on the next turn.
            }
            session.state.lock().await.model = request.model;
            json!({"ok":true})
        }
        "abort" => {
            match session.agent.as_str() {
                "pi" => {
                    session.rpc("abort", json!({})).await?;
                }
                "claude" => {
                    session.rpc("interrupt", json!({})).await?;
                }
                _ => {
                    let thread = session.thread.lock().await.clone();
                    let turn = session.turn.lock().await.clone();
                    session
                        .rpc(
                            "turn/interrupt",
                            json!({"threadId": thread, "turnId": turn}),
                        )
                        .await?;
                }
            };
            json!({"ok":true})
        }
        "command" => {
            if session.state.lock().await.busy {
                return Err((StatusCode::CONFLICT, "Agent is busy".into()));
            }
            match (session.agent.as_str(), request.text.as_str()) {
                ("pi", "new") => {
                    session.rpc("new_session", json!({})).await?;
                    session.state.lock().await.messages.clear();
                }
                ("pi", "compact") => {
                    session.rpc("compact", json!({})).await?;
                }
                ("codex", "compact") => {
                    session
                        .rpc(
                            "thread/compact/start",
                            json!({"threadId":session.thread.lock().await.clone()}),
                        )
                        .await?;
                }
                _ => return Err(bad("Use the advertised slash command as a message")),
            };
            json!({"ok":true})
        }
        "approval" => {
            let raw = session
                .approvals
                .lock()
                .await
                .get(&request.request_id)
                .cloned()
                .ok_or_else(|| bad("Approval expired or already answered"))?;
            let response = match session.agent.as_str() {
                "pi" => {
                    let method = text(&raw, "method");
                    if method == "confirm" {
                        json!({"type":"extension_ui_response","id":raw["id"],"confirmed":request.approved})
                    } else if request.approved {
                        json!({"type":"extension_ui_response","id":raw["id"],"value":request.text})
                    } else {
                        json!({"type":"extension_ui_response","id":raw["id"],"cancelled":true})
                    }
                }
                "claude" => {
                    if raw["request"]["subtype"] != "can_use_tool" {
                        return Err(bad(
                            "Unsupported Claude control request; interrupt the turn",
                        ));
                    }
                    let decision = if request.approved {
                        json!({"behavior":"allow","updatedInput":raw["request"]["input"]})
                    } else {
                        json!({"behavior":"deny","message":"Denied on phone"})
                    };
                    json!({"type":"control_response","response":{"subtype":"success","request_id":raw["request_id"],"response":decision}})
                }
                _ => {
                    let method = text(&raw, "method");
                    if !method.ends_with("requestApproval") {
                        return Err(bad("Unsupported request; interrupt the turn"));
                    }
                    json!({"id":raw["id"],"result":{"decision":if request.approved {"accept"} else {"decline"}}})
                }
            };
            session.write(response).await?;
            session.approvals.lock().await.remove(&request.request_id);
            session
                .state
                .lock()
                .await
                .approvals
                .retain(|a| a.id != request.request_id);
            json!({"ok":true})
        }
        _ => return Err(bad("Unknown action")),
    };
    Ok(Json(response))
}
