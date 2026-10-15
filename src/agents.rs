//! Long-lived provider-native JSONL adapters for daemon-owned sessions.
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
    #[serde(skip_serializing_if = "Option::is_none")]
    tool: Option<transcripts::Tool>,
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
    questions: Vec<Question>,
}
#[derive(Serialize, Clone)]
struct Question {
    id: String,
    title: String,
    prompt: String,
    options: Vec<QuestionOption>,
    multiple: bool,
    other: bool,
    secret: bool,
}
#[derive(Serialize, Clone)]
struct QuestionOption {
    label: String,
    description: String,
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
                    json!({"clientInfo":{"name":"agentmux","title":"AgentMux","version":"0.3.0"}}),
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
                "agent_settled" => {
                    state.busy = false;
                    state.approvals.clear();
                    self.approvals.lock().await.clear();
                }
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
                "tool_execution_start" | "tool_execution_update" | "tool_execution_end" => {
                    let result = if kind == "tool_execution_update" {
                        &value["partialResult"]
                    } else {
                        &value["result"]
                    };
                    tool_message(
                        &mut state,
                        &text(&value, "toolCallId"),
                        transcripts::Tool {
                            name: text(&value, "toolName"),
                            input: pretty(&value["args"]),
                            output: content(&result["content"]),
                            status: if kind != "tool_execution_end" {
                                "running"
                            } else if value["isError"] == true {
                                "error"
                            } else {
                                "completed"
                            }
                            .into(),
                        },
                    );
                }
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
                            questions: vec![],
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
                    record_claude_tools(&mut state, &value);
                    let answer = content(&value["message"]["content"]);
                    state.messages.retain(|m| m.id != "stream");
                    if !answer.is_empty() {
                        let id = value["uuid"]
                            .as_str()
                            .or(value["message"]["id"].as_str())
                            .map(String::from)
                            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
                        upsert(&mut state, &id, "assistant", answer, false);
                    }
                }
                "user" => record_claude_tools(&mut state, &value),
                "result" => {
                    state.busy = false;
                    state.approvals.clear();
                    self.approvals.lock().await.clear();
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
                        kind: if request["subtype"] != "can_use_tool" {
                            "unsupported"
                        } else if request["tool_name"] == "AskUserQuestion" {
                            "questions"
                        } else {
                            "confirm"
                        }
                        .into(),
                        questions: if request["tool_name"] == "AskUserQuestion" {
                            questions(&request["input"]["questions"], true)
                        } else {
                            vec![]
                        },
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
                        state.approvals.clear();
                        self.approvals.lock().await.clear();
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
                    "serverRequest/resolved" => {
                        let key = params["requestId"].to_string();
                        state.approvals.retain(|a| a.id != key);
                        self.approvals.lock().await.remove(&key);
                    }
                    "item/started" | "item/completed" => {
                        let item = &params["item"];
                        let id = text(item, "id");
                        if item["type"] == "agentMessage" {
                            upsert(&mut state, &id, "assistant", text(item, "text"), false);
                        } else if let Some(tool) = codex_tool(item, kind == "item/started") {
                            tool_message(&mut state, &id, tool);
                        }
                    }
                    "error" => state.error = Some(params.to_string()),
                    _ => {
                        if let Some(id) = value.get("id") {
                            let key = id.to_string();
                            let supported =
                                codex_confirm(kind) || kind == "item/permissions/requestApproval";
                            let (title, detail) = codex_request_description(kind, params);
                            state.approvals.push(Approval {
                                id: key.clone(),
                                title,
                                detail,
                                options: vec![],
                                kind: if kind == "item/tool/requestUserInput" {
                                    "questions"
                                } else if supported {
                                    "confirm"
                                } else {
                                    "unsupported"
                                }
                                .into(),
                                questions: if kind == "item/tool/requestUserInput" {
                                    questions(&params["questions"], false)
                                } else {
                                    vec![]
                                },
                            });
                            self.approvals.lock().await.insert(key, value.clone());
                        }
                    }
                }
            }
        }
        let mut bytes: usize = state.messages.iter().map(message_size).sum();
        while state.messages.len() > 500 || (bytes > 2 * 1024 * 1024 && state.messages.len() > 1) {
            let removed = state.messages.remove(0);
            bytes = bytes.saturating_sub(message_size(&removed));
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
            Some("tool_result") => content(&v["content"]),
            _ => String::new(),
        })
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}
fn pretty(value: &Value) -> String {
    if value.is_null() {
        String::new()
    } else if let Some(s) = value.as_str() {
        s.into()
    } else {
        serde_json::to_string_pretty(value).unwrap_or_default()
    }
}
fn codex_confirm(method: &str) -> bool {
    // Permissions and user-input requests have DIFFERENT response schemas.
    matches!(
        method,
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval"
    )
}
fn message_size(message: &ChatMessage) -> usize {
    message.text.len()
        + message
            .tool
            .as_ref()
            .map(|t| t.name.len() + t.input.len() + t.output.len())
            .unwrap_or_default()
}
fn codex_request_description(method: &str, params: &Value) -> (String, String) {
    match method {
        "item/tool/requestUserInput" => ("需要你的回答".into(), String::new()),
        "item/commandExecution/requestApproval" => (
            "允许运行命令？".into(),
            format!(
                "{}\n{}\n{}",
                pretty(&params["command"]),
                text(params, "cwd"),
                text(params, "reason")
            ),
        ),
        "item/fileChange/requestApproval" => (
            "允许修改文件？".into(),
            format!(
                "{}\n{}",
                text(params, "reason"),
                pretty(&params["grantRoot"])
            ),
        ),
        "item/permissions/requestApproval" => (
            "授予当前任务所需权限？".into(),
            format!(
                "{}\n仅对当前任务有效。\n{}",
                text(params, "reason"),
                pretty(&params["permissions"])
            ),
        ),
        _ => (
            "需要在 Mac 上处理的请求".into(),
            format!("{}\n{}", method, pretty(params)),
        ),
    }
}
fn questions(value: &Value, claude: bool) -> Vec<Question> {
    array(value)
        .iter()
        .map(|q| Question {
            id: text(q, if claude { "question" } else { "id" }),
            title: text(q, "header"),
            prompt: text(q, "question"),
            options: array(&q["options"])
                .iter()
                .map(|o| QuestionOption {
                    label: text(o, "label"),
                    description: text(o, "description"),
                })
                .collect(),
            multiple: claude && q["multiSelect"] == true,
            other: claude || q["isOther"] == true || array(&q["options"]).is_empty(),
            secret: q["isSecret"] == true,
        })
        .collect()
}
fn validate_answers(questions: &[Question], answers: &HashMap<String, Vec<String>>) -> Result<()> {
    if questions.is_empty() || answers.len() != questions.len() {
        return Err(bad("Answer every requested question"));
    }
    for question in questions {
        let values = answers
            .get(&question.id)
            .ok_or_else(|| bad("Missing question answer"))?;
        if values.is_empty()
            || (!question.multiple && values.len() != 1)
            || values.iter().any(|a| {
                a.trim().is_empty()
                    || a.len() > 16384
                    || (!question.other && !question.options.iter().any(|o| o.label == *a))
            })
        {
            return Err(bad("Invalid question answer"));
        }
    }
    Ok(())
}
fn codex_approval_response(
    raw: &Value,
    approved: bool,
    answers: &HashMap<String, Vec<String>>,
) -> Result<Value> {
    let method = raw["method"].as_str().unwrap_or_default();
    if codex_confirm(method) {
        return Ok(json!({"decision":if approved {"accept"}else{"decline"}}));
    }
    if method == "item/permissions/requestApproval" {
        let permissions = &raw["params"]["permissions"];
        if !permissions.is_object() {
            return Err(bad("Invalid permissions request"));
        }
        return Ok(
            json!({"permissions":if approved {permissions.clone()} else {json!({})},"scope":"turn"}),
        );
    }
    if method == "item/tool/requestUserInput" {
        let fields = questions(&raw["params"]["questions"], false);
        if approved {
            validate_answers(&fields, answers)?;
        }
        return Ok(
            json!({"answers":fields.iter().map(|q|(q.id.clone(),json!({"answers":if approved {answers[&q.id].clone()} else {vec![]}}))).collect::<serde_json::Map<_,_>>()}),
        );
    }
    Err(bad("Unsupported request; interrupt the turn"))
}
fn codex_tool(item: &Value, started: bool) -> Option<transcripts::Tool> {
    let kind = item["type"].as_str()?;
    let (name, input, output) = match kind {
        "commandExecution" => (
            "运行命令".into(),
            pretty(&item["command"]),
            text(item, "aggregatedOutput"),
        ),
        "fileChange" => ("修改文件".into(), pretty(&item["changes"]), String::new()),
        "mcpToolCall" => (
            format!("{} / {}", text(item, "server"), text(item, "tool")),
            pretty(&item["arguments"]),
            pretty(&item["result"]),
        ),
        "dynamicToolCall" => (
            text(item, "tool"),
            pretty(&item["arguments"]),
            pretty(&item["contentItems"]),
        ),
        "webSearch" => (
            "搜索网页".into(),
            text(item, "query"),
            pretty(&item["action"]),
        ),
        _ => return None,
    };
    Some(transcripts::Tool {
        name,
        input,
        output,
        status: if started {
            "running"
        } else if item["status"] == "failed"
            || item["status"] == "declined"
            || item["exitCode"].as_i64().is_some_and(|code| code != 0)
        {
            "error"
        } else {
            "completed"
        }
        .into(),
    })
}
fn record_claude_tools(state: &mut Snapshot, value: &Value) {
    let mut record = value.clone();
    if record["message"]["role"].is_null() {
        record["message"]["role"] = record["type"].clone();
    }
    for message in transcripts::parse("claude", &[record]) {
        if let Some(tool) = message.tool {
            tool_message(state, &message.id, tool);
        }
    }
}
fn tool_message(state: &mut Snapshot, id: &str, mut tool: transcripts::Tool) {
    if let Some(old) = state
        .messages
        .iter()
        .find(|m| m.id == id)
        .and_then(|m| m.tool.as_ref())
    {
        if tool.input.is_empty() {
            tool.input = old.input.clone();
        }
        if tool.name.is_empty() || tool.name == "工具" {
            tool.name = old.name.clone();
        }
    }
    tool.input = tool.input.chars().take(32768).collect();
    tool.output = tool.output.chars().take(65536).collect();
    upsert(state, id, "tool", String::new(), false);
    if let Some(message) = state.messages.iter_mut().find(|m| m.id == id) {
        message.tool = Some(tool);
    }
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
            tool: None,
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
    #[serde(default)]
    answers: HashMap<String, Vec<String>>,
    #[serde(default)]
    attachments: Vec<String>,
}
pub async fn action(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(mut request): Json<Action>,
) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let session = find(&app, &id).await?;
    let mut uploaded_files = Vec::new();
    if request.action == "message" {
        (request.text, uploaded_files) =
            attachments::prepare(&app, &request.text, &request.attachments).await?;
    } else if !request.attachments.is_empty() {
        return Err(bad("Only messages accept attachments"));
    }
    let _operation =
        if ["message", "model", "command", "approval"].contains(&request.action.as_str()) {
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
            let images = if session.agent == "codex" {
                vec![]
            } else {
                attachments::images(&uploaded_files).await?
            };
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
            let result = match session.agent.as_str() {
                "pi" => {
                    session
                        .rpc("prompt", json!({"message":request.text,"images":images}))
                        .await
                }
                "claude" => {
                    let content = if images.is_empty() {
                        json!(request.text)
                    } else {
                        let mut content = vec![json!({"type":"text","text":request.text})];
                        content.extend(images.iter().map(|image|json!({"type":"image","source":{"type":"base64","media_type":image["mimeType"],"data":image["data"]}})));
                        json!(content)
                    };
                    session.write(json!({"type":"user","message":{"role":"user","content":content},"parent_tool_use_id":null,"session_id":""})).await.map(|_|json!({}))
                }
                _ => {
                    let thread = session.thread.lock().await.clone();
                    let model = session.state.lock().await.model.clone();
                    let mut input = vec![json!({"type":"text","text":request.text})];
                    input.extend(
                        uploaded_files
                            .iter()
                            .filter(|file| file.mime_type.starts_with("image/"))
                            .map(|file| json!({"type":"localImage","path":file.path})),
                    );
                    session
                        .rpc(
                            "turn/start",
                            json!({"threadId":thread,"model":model,"input":input}),
                        )
                        .await
                }
            };
            if session.agent == "pi"
                && result
                    .as_ref()
                    .is_ok_and(|value| value["disposition"] == "handled")
            {
                session.state.lock().await.busy = false;
            }
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
                    let mut input = raw["request"]["input"].clone();
                    if request.approved && raw["request"]["tool_name"] == "AskUserQuestion" {
                        let fields = questions(&input["questions"], true);
                        validate_answers(&fields, &request.answers)?;
                        input["answers"] = Value::Object(
                            request
                                .answers
                                .iter()
                                .map(|(key, values)| (key.clone(), json!(values.join(", "))))
                                .collect(),
                        );
                    }
                    let decision = if request.approved {
                        json!({"behavior":"allow","updatedInput":input})
                    } else {
                        json!({"behavior":"deny","message":"Denied on phone"})
                    };
                    json!({"type":"control_response","response":{"subtype":"success","request_id":raw["request_id"],"response":decision}})
                }
                _ => {
                    let result = codex_approval_response(&raw, request.approved, &request.answers)?;
                    json!({"id":raw["id"],"result":result})
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_permission_requests_use_permission_profiles_not_command_decisions() {
        let raw = json!({"method":"item/permissions/requestApproval","params":{"permissions":{"network":{"enabled":true}}}});
        let accepted = codex_approval_response(&raw, true, &HashMap::new()).unwrap();
        assert_eq!(
            accepted,
            json!({"permissions":{"network":{"enabled":true}},"scope":"turn"})
        );
        assert_eq!(
            codex_approval_response(&raw, false, &HashMap::new()).unwrap(),
            json!({"permissions":{},"scope":"turn"})
        );
        assert!(!codex_confirm("item/permissions/requestApproval"));
        assert!(codex_confirm("item/commandExecution/requestApproval"));
        assert!(
            codex_approval_response(
                &json!({"method":"unknown/requestApproval"}),
                true,
                &HashMap::new()
            )
            .is_err()
        );
    }
    #[test]
    fn codex_questions_require_valid_answers_and_preserve_the_wire_shape() {
        let raw = json!({"method":"item/tool/requestUserInput","params":{"questions":[{"id":"q","header":"Database","question":"Choose one","options":[{"label":"SQLite","description":"Local"}]}]}});
        assert!(codex_approval_response(&raw, true, &HashMap::new()).is_err());
        let mut answers = HashMap::from([("q".into(), vec!["SQLite".into()])]);
        assert_eq!(
            codex_approval_response(&raw, true, &answers).unwrap(),
            json!({"answers":{"q":{"answers":["SQLite"]}}})
        );
        answers.insert("q".into(), vec!["unknown".into()]);
        assert!(codex_approval_response(&raw, true, &answers).is_err());
        assert_eq!(
            codex_approval_response(&raw, false, &HashMap::new()).unwrap(),
            json!({"answers":{"q":{"answers":[]}}})
        );
    }
    #[test]
    fn claude_tools_keep_inputs_when_results_arrive() {
        let mut state = Snapshot::default();
        record_claude_tools(
            &mut state,
            &json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls"}}]}}),
        );
        record_claude_tools(
            &mut state,
            &json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"file.txt","is_error":false}]}}),
        );
        assert_eq!(state.messages.len(), 1);
        let tool = state.messages[0].tool.as_ref().unwrap();
        assert_eq!(tool.name, "Bash");
        assert!(tool.input.contains("ls"));
        assert_eq!(tool.output, "file.txt");
        assert_eq!(tool.status, "completed");
    }
}
