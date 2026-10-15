//! Discover live Agent processes beneath every pane on the configured tmux server.
use crate::*;
use std::collections::{HashMap, HashSet, VecDeque};

#[derive(Clone, Serialize)]
pub struct Session {
    pub id: String,
    pub name: String,
    pub directory: PathBuf,
    pub command: String,
    pub mode: &'static str,
    pub window_id: String,
    pub window_name: String,
    pub session_name: String,
    pub pane_pid: u32,
    pub agent_pid: u32,
}

#[derive(Clone, Debug)]
pub struct Process {
    pub pid: u32,
    pub parent: u32,
    pub executable: String,
    pub arguments: String,
}

fn columns(line: &str) -> Option<(u32, u32, String)> {
    let line = line.trim();
    let (pid, rest) = line.split_once(char::is_whitespace)?;
    let (parent, value) = rest.trim_start().split_once(char::is_whitespace)?;
    Some((pid.parse().ok()?, parent.parse().ok()?, value.trim().into()))
}

pub async fn processes() -> Result<HashMap<u32, Process>> {
    async fn read(column: &str) -> Result<String> {
        let output = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            Command::new("/bin/ps")
                .args(["-axo", column])
                .kill_on_drop(true)
                .output(),
        )
        .await
        .map_err(internal)?
        .map_err(internal)?;
        if !output.status.success() {
            return Err(internal(
                "Unable to inspect processes for tmux Agent discovery",
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }
    let (commands, arguments) =
        tokio::try_join!(read("pid=,ppid=,comm="), read("pid=,ppid=,args="))?;
    let arguments: HashMap<_, _> = arguments
        .lines()
        .filter_map(columns)
        .map(|(pid, _, args)| (pid, args))
        .collect();
    Ok(commands
        .lines()
        .filter_map(columns)
        .map(|(pid, parent, executable)| {
            (
                pid,
                Process {
                    pid,
                    parent,
                    executable,
                    arguments: arguments.get(&pid).cloned().unwrap_or_default(),
                },
            )
        })
        .collect())
}

fn basename(value: &str) -> &str {
    FsPath::new(value)
        .file_name()
        .and_then(|v| v.to_str())
        .unwrap_or(value)
}

fn provider(process: &Process, agents: &Agents) -> Option<&'static str> {
    let executable = basename(&process.executable);
    for name in ["codex", "claude", "pi"] {
        if executable == name {
            return Some(name);
        }
    }
    let configured = [
        ("codex", &agents.codex),
        ("claude", &agents.claude),
        ("pi", &agents.pi),
    ];
    for (name, path) in configured {
        if process.executable == *path
            || FsPath::new(path)
                .canonicalize()
                .is_ok_and(|resolved| resolved == FsPath::new(&process.executable))
            || (basename(path) == executable
                && !["node", "bun", "sh", "bash", "python3"].contains(&executable))
        {
            return Some(name);
        }
    }
    if ![
        "node", "bun", "deno", "sh", "zsh", "bash", "dash", "python", "python3",
    ]
    .contains(&executable)
    {
        return None;
    }
    // Node's process.title replaces argv on supported systems (Pi does this).
    if let Some(title) = process.arguments.split_whitespace().next()
        && ["codex", "claude", "pi"].contains(&title)
    {
        return Some(match title {
            "codex" => "codex",
            "claude" => "claude",
            _ => "pi",
        });
    }
    let mut arguments = process.arguments.split_whitespace().skip(1);
    while let Some(argument) = arguments.next() {
        if ["-c", "-e", "--eval", "--print"].contains(&argument) {
            return None;
        }
        if ["--require", "-r", "--import", "--loader"].contains(&argument) {
            arguments.next();
            continue;
        }
        if argument.starts_with('-') {
            continue;
        }
        for (name, path) in configured {
            if argument == path || basename(argument) == name {
                return Some(name);
            }
        }
        if argument.contains("/pi-coding-agent/") && argument.ends_with("/cli.js") {
            return Some("pi");
        }
        if argument.contains("/@anthropic-ai/claude-code/") && argument.ends_with("/cli.js") {
            return Some("claude");
        }
        if argument.contains("/@openai/codex/") && argument.ends_with("/codex.js") {
            return Some("codex");
        }
        return None;
    }
    None
}

pub fn agent_in_tree<'a>(
    root: u32,
    processes: &'a HashMap<u32, Process>,
    agents: &Agents,
) -> Option<(&'static str, &'a Process)> {
    let mut queue = VecDeque::from([root]);
    let mut seen = HashSet::new();
    while let Some(pid) = queue.pop_front() {
        if !seen.insert(pid) {
            continue;
        }
        if let Some(process) = processes.get(&pid)
            && let Some(provider) = provider(process, agents)
        {
            return Some((provider, process));
        }
        let mut children: Vec<_> = processes
            .values()
            .filter(|p| p.parent == pid)
            .map(|p| p.pid)
            .collect();
        children.sort_unstable();
        queue.extend(children);
    }
    None
}

pub async fn discover(app: &App) -> Result<Vec<Session>> {
    let panes = match tmux(app, &["list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}\t#{pane_current_path}\t#{window_id}\t#{window_name}\t#{session_name}\t#{window_index}\t#{pane_index}"]).await {
        Ok(value) => value,
        Err((_, message)) if message.contains("no server running") || message.contains("no sessions") || message.contains("error connecting") => return Ok(vec![]),
        Err(error) => return Err(error),
    };
    let processes = processes().await?;
    let config = app.config.lock().await;
    let mut sessions = Vec::new();
    for line in panes.lines() {
        let fields: Vec<_> = line.split('\t').collect();
        if fields.len() != 8 {
            continue;
        }
        let Ok(pane_pid) = fields[1].parse() else {
            continue;
        };
        let Some((provider, process)) = agent_in_tree(pane_pid, &processes, &config.agents) else {
            continue;
        };
        sessions.push(Session {
            id: fields[0].into(),
            name: format!("{}:{} · {}", fields[5], fields[6], fields[4]),
            directory: fields[2].into(),
            command: provider.into(),
            mode: "tmux",
            window_id: fields[3].into(),
            window_name: fields[4].into(),
            session_name: fields[5].into(),
            pane_pid,
            agent_pid: process.pid,
        });
    }
    Ok(sessions)
}

pub async fn find(app: &App, id: &str) -> Result<Session> {
    if !id.starts_with('%') || id.len() < 2 || !id[1..].bytes().all(|c| c.is_ascii_digit()) {
        return Err(bad("Invalid Agent pane ID"));
    }
    discover(app)
        .await?
        .into_iter()
        .find(|session| session.id == id)
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                "This window no longer contains a running Agent".into(),
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn agents() -> Agents {
        Agents {
            codex: "/usr/local/bin/codex".into(),
            claude: "/usr/local/bin/claude".into(),
            pi: "/usr/local/bin/pi".into(),
        }
    }
    fn process(pid: u32, parent: u32, exe: &str, args: &str) -> Process {
        Process {
            pid,
            parent,
            executable: exe.into(),
            arguments: args.into(),
        }
    }
    #[test]
    fn finds_agents_below_shell_wrappers_and_prefers_the_outer_agent() {
        let processes = [
            process(1, 0, "zsh", "zsh"),
            process(2, 1, "sh", "sh launcher.sh"),
            process(3, 2, "claude", "claude"),
            process(4, 3, "codex", "codex exec task"),
        ]
        .into_iter()
        .map(|p| (p.pid, p))
        .collect();
        assert_eq!(
            agent_in_tree(1, &processes, &agents()).map(|(p, v)| (p, v.pid)),
            Some(("claude", 3))
        );
    }
    #[test]
    fn recognizes_node_launchers_without_matching_command_text_or_window_titles() {
        assert_eq!(
            provider(
                &process(
                    1,
                    0,
                    "node",
                    "node /tmp/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
                ),
                &agents()
            ),
            Some("pi")
        );
        assert_eq!(
            provider(&process(1, 0, "sh", "sh -c echo codex"), &agents()),
            None
        );
        assert_eq!(
            provider(
                &process(1, 0, "vim", "vim /usr/local/bin/claude"),
                &agents()
            ),
            None
        );
        assert_eq!(
            provider(&process(1, 0, "node", "node unrelated.js codex"), &agents()),
            None
        );
    }
    #[test]
    fn ignores_unrelated_processes_and_handles_cycles() {
        let processes = [
            process(1, 2, "zsh", "zsh"),
            process(2, 1, "sleep", "sleep 100"),
            process(3, 0, "codex", "codex"),
        ]
        .into_iter()
        .map(|p| (p.pid, p))
        .collect();
        assert!(agent_in_tree(1, &processes, &agents()).is_none());
    }
}
