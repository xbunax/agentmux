//! Provider-owned JSONL is conversation data; terminal screen captures are not.
use crate::*;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    io::{BufRead, Read, Seek, SeekFrom},
};

const MAX_HISTORY: u64 = 8 * 1024 * 1024;

#[derive(Clone, Serialize, Debug)]
pub struct Tool {
    pub name: String,
    pub input: String,
    pub output: String,
    pub status: String,
}
#[derive(Clone, Serialize, Debug)]
pub struct Message {
    pub id: String,
    pub role: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<Tool>,
}
#[derive(Clone, Serialize)]
pub struct Conversation {
    pub id: String,
    pub title: String,
    pub modified: u64,
    #[serde(skip)]
    pub path: PathBuf,
}
pub fn home(variable: &str, fallback: &str) -> PathBuf {
    std::env::var_os(variable)
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(fallback)
        })
}
fn header(path: &FsPath) -> Option<Value> {
    let file = std::fs::File::open(path).ok()?;
    let mut line = String::new();
    std::io::BufReader::new(file.take(65536))
        .read_line(&mut line)
        .ok()?;
    serde_json::from_str(&line).ok()
}
fn walk(path: &FsPath, depth: usize, files: &mut Vec<PathBuf>) {
    if depth == 0 || files.len() >= 10000 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        if files.len() >= 10000 {
            break;
        }
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            walk(&entry.path(), depth - 1, files);
        } else if kind.is_file() && entry.path().extension().is_some_and(|v| v == "jsonl") {
            files.push(entry.path());
        }
    }
}
pub fn candidates(provider: &str, cwd: &FsPath) -> Vec<Conversation> {
    let mut files = Vec::new();
    match provider {
        "codex" => walk(
            &home("CODEX_HOME", ".codex").join("sessions"),
            4,
            &mut files,
        ),
        "claude" => {
            let encoded: String = cwd
                .to_string_lossy()
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect();
            walk(
                &home("CLAUDE_CONFIG_DIR", ".claude")
                    .join("projects")
                    .join(encoded),
                1,
                &mut files,
            );
        }
        "pi" => {
            let encoded = format!(
                "--{}--",
                cwd.to_string_lossy()
                    .trim_start_matches(['/', '\\'])
                    .replace(['/', '\\', ':'], "-")
            );
            walk(
                &home("PI_CODING_AGENT_DIR", ".pi/agent")
                    .join("sessions")
                    .join(encoded),
                1,
                &mut files,
            );
        }
        _ => return vec![],
    }
    files
        .into_iter()
        .filter_map(|path| {
            // Claude's first line can be metadata without cwd; its project directory is already scoped.
            if provider != "claude" {
                let head = header(&path)?;
                let info = if provider == "codex" {
                    &head["payload"]
                } else {
                    &head
                };
                if info["cwd"].as_str().map(FsPath::new) != Some(cwd) {
                    return None;
                }
            }
            let metadata = path.metadata().ok()?;
            let modified = metadata
                .modified()
                .ok()?
                .duration_since(std::time::UNIX_EPOCH)
                .ok()?
                .as_secs();
            let id = format!("{:x}", Sha256::digest(path.as_os_str().as_encoded_bytes()));
            let title = path.file_stem()?.to_string_lossy().into_owned();
            Some(Conversation {
                id,
                title,
                modified,
                path,
            })
        })
        .collect::<Vec<_>>()
        .tap_sort()
}
trait SortConversations {
    fn tap_sort(self) -> Self;
}
impl SortConversations for Vec<Conversation> {
    fn tap_sort(mut self) -> Self {
        self.sort_by_key(|c| std::cmp::Reverse(c.modified));
        self.truncate(100);
        self
    }
}

pub fn read(provider: &str, path: &FsPath) -> std::io::Result<Vec<Message>> {
    let mut file = std::fs::File::open(path)?;
    let size = file.metadata()?.len();
    let mut bytes = Vec::new();
    if size > MAX_HISTORY {
        file.seek(SeekFrom::Start(size - MAX_HISTORY))?;
    }
    file.take(MAX_HISTORY).read_to_end(&mut bytes)?;
    if size > MAX_HISTORY
        && let Some(end) = bytes.iter().position(|b| *b == b'\n')
    {
        bytes.drain(..=end);
    }
    // A writer can be halfway through its final JSON record. Only consume complete lines.
    let records: Vec<Value> = bytes
        .split_inclusive(|b| *b == b'\n')
        .filter(|line| line.last() == Some(&b'\n'))
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect();
    Ok(parse(provider, &records))
}
fn string(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().into()
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
fn texts(value: &Value) -> String {
    if let Some(s) = value.as_str() {
        return s.into();
    }
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| {
            if ["text", "input_text", "output_text"]
                .contains(&v["type"].as_str().unwrap_or_default())
            {
                v["text"].as_str()
            } else {
                None
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}
fn put(messages: &mut Vec<Message>, mut message: Message) {
    message.text = message.text.chars().take(65536).collect();
    if let Some(tool) = &mut message.tool {
        tool.input = tool.input.chars().take(32768).collect();
        tool.output = tool.output.chars().take(65536).collect();
    }
    if let Some(old) = messages.iter_mut().find(|m| m.id == message.id) {
        *old = message;
    } else {
        messages.push(message);
    }
}
fn tool(
    messages: &mut Vec<Message>,
    id: &str,
    name: String,
    input: String,
    result: Option<(String, bool)>,
) {
    let previous = messages
        .iter()
        .find(|m| m.id == id)
        .and_then(|m| m.tool.clone());
    let (output, status) = result
        .map(|(s, error)| (s, if error { "error" } else { "completed" }))
        .unwrap_or_default();
    put(
        messages,
        Message {
            id: id.into(),
            role: "tool".into(),
            text: String::new(),
            tool: Some(Tool {
                name: if name.is_empty() {
                    previous
                        .as_ref()
                        .map(|t| t.name.clone())
                        .unwrap_or_else(|| "工具".into())
                } else {
                    name
                },
                input: if input.is_empty() {
                    previous.map(|t| t.input).unwrap_or_default()
                } else {
                    input
                },
                output,
                status: if status.is_empty() { "running" } else { status }.into(),
            }),
        },
    );
}
pub fn parse(provider: &str, records: &[Value]) -> Vec<Message> {
    let mut messages = Vec::new();
    // Pi stores a tree. Follow the current leaf, not abandoned branches after /fork or navigation.
    let branch: HashSet<String> = if provider == "pi" {
        let parents: HashMap<_, _> = records
            .iter()
            .filter_map(|r| Some((r["id"].as_str()?, r["parentId"].as_str())))
            .collect();
        let mut leaf = records.iter().rev().find_map(|r| r["id"].as_str());
        let mut branch = HashSet::new();
        while let Some(id) = leaf {
            if !branch.insert(id.to_owned()) {
                break;
            }
            leaf = parents.get(id).copied().flatten();
        }
        branch
    } else {
        HashSet::new()
    };
    for (index, record) in records.iter().enumerate() {
        if record["isSidechain"] == true {
            continue;
        }
        if provider == "pi" && !branch.contains(record["id"].as_str().unwrap_or_default()) {
            continue;
        }
        let id = record["uuid"]
            .as_str()
            .or(record["id"].as_str())
            .map(String::from)
            .unwrap_or_else(|| format!("record-{index}"));
        if provider == "codex" {
            if record["type"] != "response_item" {
                continue;
            }
            let p = &record["payload"];
            match p["type"].as_str().unwrap_or_default() {
                "message" if p["role"] == "user" || p["role"] == "assistant" => {
                    let text = texts(&p["content"]);
                    if !text.is_empty() {
                        put(
                            &mut messages,
                            Message {
                                id,
                                role: string(p, "role"),
                                text,
                                tool: None,
                            },
                        );
                    }
                }
                "function_call" | "custom_tool_call" => tool(
                    &mut messages,
                    &format!("tool-{}", string(p, "call_id")),
                    string(p, "name"),
                    pretty(p.get("arguments").unwrap_or(&p["input"])),
                    None,
                ),
                "function_call_output" | "custom_tool_call_output" => tool(
                    &mut messages,
                    &format!("tool-{}", string(p, "call_id")),
                    String::new(),
                    String::new(),
                    Some((pretty(&p["output"]), false)),
                ),
                _ => {}
            }
        } else {
            if provider == "pi" && record["type"] != "message" {
                continue;
            }
            if provider == "claude" && record["type"] != "user" && record["type"] != "assistant" {
                continue;
            }
            let message = &record["message"];
            let role = string(message, "role");
            let content = &message["content"];
            if role == "toolResult" {
                tool(
                    &mut messages,
                    &format!("tool-{}", string(message, "toolCallId")),
                    string(message, "toolName"),
                    String::new(),
                    Some((texts(content), message["isError"] == true)),
                );
                continue;
            }
            if !["user", "assistant"].contains(&role.as_str()) {
                continue;
            }
            let text = texts(content);
            // Claude streaming chunks with the same message ID replace the previous text.
            let id = message["id"].as_str().map(String::from).unwrap_or(id);
            if !text.is_empty() {
                put(
                    &mut messages,
                    Message {
                        id,
                        role,
                        text,
                        tool: None,
                    },
                );
            }
            for block in content.as_array().into_iter().flatten() {
                match block["type"].as_str().unwrap_or_default() {
                    "tool_use" | "toolCall" => tool(
                        &mut messages,
                        &format!("tool-{}", string(block, "id")),
                        string(block, "name"),
                        pretty(block.get("input").unwrap_or(&block["arguments"])),
                        None,
                    ),
                    "tool_result" => tool(
                        &mut messages,
                        &format!("tool-{}", string(block, "tool_use_id")),
                        String::new(),
                        String::new(),
                        Some((texts(&block["content"]), block["is_error"] == true)),
                    ),
                    _ => {}
                }
            }
        }
    }
    if messages.len() > 300 {
        messages.drain(..messages.len() - 300);
    }
    let size = |m: &Message| {
        m.text.len()
            + m.tool
                .as_ref()
                .map(|t| t.input.len() + t.output.len() + t.name.len())
                .unwrap_or_default()
    };
    let mut bytes: usize = messages.iter().map(size).sum();
    while bytes > 2 * 1024 * 1024 && messages.len() > 1 {
        bytes -= size(&messages.remove(0));
    }
    messages
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn claude_merges_streams_and_tool_results_without_duplicate_messages() {
        let records = vec![
            json!({"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Hello"},{"type":"tool_use","id":"t1","name":"Read","input":{"path":"a"}}]}}),
            json!({"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Hello world"}]}}),
            json!({"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"result"}]}}),
        ];
        let messages = parse("claude", &records);
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].text, "Hello world");
        let tool = messages[1].tool.as_ref().unwrap();
        assert_eq!(
            (&*tool.name, &*tool.output, &*tool.status),
            ("Read", "result", "completed")
        );
    }
    #[test]
    fn pi_uses_the_active_branch_and_ignores_abandoned_turns() {
        let records = vec![
            json!({"type":"message","id":"a","parentId":null,"message":{"role":"user","content":"first"}}),
            json!({"type":"message","id":"b","parentId":"a","message":{"role":"assistant","content":[{"type":"text","text":"abandoned"}]}}),
            json!({"type":"message","id":"c","parentId":"a","message":{"role":"assistant","content":[{"type":"text","text":"current"}]}}),
        ];
        let messages = parse("pi", &records);
        assert_eq!(
            messages.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(),
            vec!["first", "current"]
        );
    }
    #[test]
    fn codex_uses_response_items_once_and_keeps_tool_details() {
        let records = vec![
            json!({"type":"event_msg","payload":{"type":"agent_message","message":"duplicate"}}),
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}),
            json!({"type":"response_item","payload":{"type":"function_call","call_id":"c","name":"exec_command","arguments":"ls"}}),
            json!({"type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":"files"}}),
        ];
        let messages = parse("codex", &records);
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].text, "answer");
        assert_eq!(messages[1].tool.as_ref().unwrap().input, "ls");
    }
    #[test]
    fn incomplete_records_are_not_displayed_until_committed() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        use std::io::Write;
        file.write_all(b"{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":\"ok\"}}\n{\"type\":").unwrap();
        assert_eq!(read("codex", file.path()).unwrap().len(), 1);
    }
}
