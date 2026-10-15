//! Live terminal transport. No provider parser is needed to operate a pane.
use crate::*;
use axum::{body::Body, response::Response};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    process::Stdio,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;

#[derive(Default)]
pub struct Manager {
    leases: Mutex<HashMap<String, Arc<Lease>>>,
}
struct Lease {
    pane: String,
    owner: String,
    identity: Identity,
    created: Instant,
    active: AtomicBool,
    started: AtomicBool,
    cancelled: AtomicBool,
    writes: Mutex<WriteState>,
    agent: Option<(u32, String)>,
}
#[derive(Default)]
struct WriteState {
    sequence: u64,
    ids: std::collections::HashSet<String>,
}
impl WriteState {
    // Called while holding the generation's write mutex, before any side effect.
    fn claim(&mut self, sequence: u64, id: String) -> Result<()> {
        if self.sequence.checked_add(1) != Some(sequence)
            || id.len() > 64
            || uuid::Uuid::parse_str(&id).is_err()
            || self.ids.contains(&id)
        {
            return Err(conflict(
                "Duplicate or out-of-order input; inspect terminal before retrying",
            ));
        }
        if self.ids.len() >= 4096 {
            return Err(conflict("Input generation exhausted; reopen terminal"));
        }
        self.sequence = sequence;
        self.ids.insert(id);
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Identity {
    server: String,
    pane: String,
    process: String,
    command: String,
}
#[derive(Clone)]
struct Pane {
    identity: Identity,
    session: String,
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    alternate: bool,
    cursor: bool,
    paste: bool,
    insert: bool,
    wrap: bool,
    origin: bool,
    keypad: bool,
    application_cursor: bool,
    top: usize,
    bottom: usize,
}
fn conflict(message: &str) -> Error {
    (StatusCode::CONFLICT, message.into())
}
fn owner(headers: &HeaderMap) -> String {
    format!(
        "{:x}",
        Sha256::digest(
            headers
                .get("authorization")
                .map(|v| v.as_bytes())
                .unwrap_or_default()
        )
    )
}
fn validate_pane(id: &str) -> Result<()> {
    if id.len() < 2
        || id.len() > 24
        || !id.starts_with('%')
        || !id[1..].bytes().all(|c| c.is_ascii_digit())
    {
        return Err(bad("Invalid pane ID"));
    }
    Ok(())
}
async fn ps(args: &[&str]) -> Result<String> {
    let result = tokio::time::timeout(
        Duration::from_secs(3),
        Command::new("/bin/ps")
            .args(args)
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(internal)?
    .map_err(internal)?;
    if !result.status.success() {
        return Err(conflict("Process exited; reopen the terminal target"));
    }
    Ok(String::from_utf8_lossy(&result.stdout)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" "))
}
async fn pane(app: &App, id: &str) -> Result<Pane> {
    validate_pane(id)?;
    let value = tmux(app, &["display-message", "-p", "-t", id,
        "#{socket_path}\t#{pid}\t#{pane_pid}\t#{pane_tty}\t#{pane_current_command}\t#{session_id}\t#{pane_width}\t#{pane_height}\t#{cursor_x}\t#{cursor_y}\t#{alternate_on}\t#{cursor_flag}\t#{?bracket_paste_flag,1,0}\t#{insert_flag}\t#{wrap_flag}\t#{origin_flag}\t#{keypad_flag}\t#{keypad_cursor_flag}\t#{scroll_region_upper}\t#{scroll_region_lower}\t#{pane_dead}\t#{pane_id}"]).await?;
    let f: Vec<_> = value.trim_end_matches('\n').split('\t').collect();
    if f.len() != 22 || f[20] == "1" || f[21] != id {
        return Err(conflict("Pane exited or changed"));
    }
    // A foreground process-group identity detects unknown TUI -> shell and exec/respawn.
    // lstart protects against PID reuse; process command protects same-PID exec.
    let tty = f[3].strip_prefix("/dev/").unwrap_or(f[3]);
    let foreground = ps(&["-t", tty, "-o", "tpgid="]).await?;
    let pgid = foreground
        .split_whitespace()
        .find(|s| s.parse::<u32>().is_ok_and(|v| v > 0))
        .ok_or_else(|| conflict("Cannot verify terminal foreground process"))?;
    let process = ps(&["-p", pgid, "-o", "pid=,lstart=,comm="]).await?;
    let server = ps(&["-p", f[1], "-o", "pid=,lstart="]).await?;
    let root = ps(&["-p", f[2], "-o", "pid=,lstart=,comm="]).await?;
    let number = |i: usize| {
        f[i].parse::<usize>()
            .map_err(|_| bad("Unsupported tmux terminal metadata"))
    };
    let width = number(6)?;
    let height = number(7)?;
    if !(2..=1000).contains(&width) || !(2..=1000).contains(&height) {
        return Err(bad("Unsupported terminal grid"));
    }
    Ok(Pane {
        identity: Identity {
            server: format!("{}:{server}", f[0]),
            pane: format!("{id}:{root}"),
            process,
            command: f[4].into(),
        },
        session: f[5].into(),
        width,
        height,
        x: number(8)?,
        y: number(9)?,
        alternate: f[10] == "1",
        cursor: f[11] == "1",
        paste: f[12] == "1",
        insert: f[13] == "1",
        wrap: f[14] == "1",
        origin: f[15] == "1",
        keypad: f[16] == "1",
        application_cursor: f[17] == "1",
        top: number(18)?,
        bottom: number(19)?,
    })
}

pub async fn list(State(app): State<Shared>, headers: HeaderMap) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let lines = tmux(&app, &["list-panes", "-a", "-F", "#{pane_id}\t#{pane_current_command}\t#{pane_current_path}\t#{session_name}\t#{window_name}\t#{pane_dead}"]).await?;
    let rows: Vec<_> = lines.lines().filter_map(|line| {
        let f: Vec<_> = line.split('\t').collect();
        (f.len() == 6 && f[5] == "0").then(|| json!({"id":f[0],"name":format!("{} · {}",f[3],f[4]),"command":f[1],"directory":f[2],"session_name":f[3],"window_name":f[4],"mode":"generic"}))
    }).collect();
    Ok(Json(json!(rows)))
}
#[derive(Deserialize)]
pub struct Open {
    expected_agent_pid: Option<u32>,
    #[serde(default)]
    generic: bool,
}
pub async fn open(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(request): Json<Open>,
) -> Result<Json<Value>> {
    authorize(&headers, &app)?;
    let current = pane(&app, &id).await?;
    if let Some(pid) = request.expected_agent_pid {
        if tmux_agents::find(&app, &id).await?.agent_pid != pid {
            return Err(conflict("Agent changed; reselect the target"));
        }
    } else if !request.generic {
        return Err(bad("Explicit generic target confirmation required"));
    }
    let agent = match request.expected_agent_pid {
        Some(pid) => Some((
            pid,
            ps(&["-p", &pid.to_string(), "-o", "pid=,lstart=,comm="]).await?,
        )),
        None => None,
    };
    let mut leases = app.terminal.leases.lock().await;
    leases.retain(|_, lease| {
        !lease.cancelled.load(Ordering::SeqCst)
            && (lease.active.load(Ordering::SeqCst)
                || lease.created.elapsed() < Duration::from_secs(30))
    });
    if leases.len() >= 32 {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "Too many terminal attachments".into(),
        ));
    }
    for old in leases
        .values()
        .filter(|lease| lease.owner == owner(&headers))
    {
        old.cancelled.store(true, Ordering::SeqCst);
        old.active.store(false, Ordering::SeqCst);
    }
    let id = uuid::Uuid::new_v4().to_string();
    leases.insert(
        id.clone(),
        Arc::new(Lease {
            pane: request_pane(&current),
            owner: owner(&headers),
            identity: current.identity.clone(),
            created: Instant::now(),
            active: AtomicBool::new(false),
            started: AtomicBool::new(false),
            cancelled: AtomicBool::new(false),
            agent,
            writes: Mutex::new(WriteState::default()),
        }),
    );
    Ok(Json(
        json!({"generation":id,"cols":current.width,"rows":current.height,"command":current.identity.command,"capabilities":{"key":true,"paste":true,"multiline_paste":current.paste}}),
    ))
}
fn request_pane(pane: &Pane) -> String {
    pane.identity.pane.split(':').next().unwrap().into()
}
async fn agent_matches(lease: &Lease) -> bool {
    match &lease.agent {
        Some((pid, identity)) => ps(&["-p", &pid.to_string(), "-o", "pid=,lstart=,comm="])
            .await
            .is_ok_and(|v| &v == identity),
        None => true,
    }
}
async fn lease(app: &App, headers: &HeaderMap, id: &str) -> Result<Arc<Lease>> {
    authorize(headers, app)?;
    let lease = app
        .terminal
        .leases
        .lock()
        .await
        .get(id)
        .cloned()
        .ok_or_else(|| conflict("Attachment expired; reopen target"))?;
    if lease.owner != owner(headers) {
        return Err((
            StatusCode::FORBIDDEN,
            "Attachment belongs to another device".into(),
        ));
    }
    if lease.cancelled.load(Ordering::SeqCst) {
        return Err(conflict("Attachment ended; reopen target"));
    }
    Ok(lease)
}
pub async fn close(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode> {
    let lease = lease(&app, &headers, &id).await?;
    lease.cancelled.store(true, Ordering::SeqCst);
    lease.active.store(false, Ordering::SeqCst);
    Ok(StatusCode::NO_CONTENT)
}
struct Invalidate(Arc<Lease>);
impl Drop for Invalidate {
    fn drop(&mut self) {
        self.0.active.store(false, Ordering::SeqCst);
        self.0.cancelled.store(true, Ordering::SeqCst);
    }
}
fn unescape(bytes: &[u8]) -> Result<Vec<u8>> {
    let mut output = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            // capture-pane -C escapes literal backslashes as \\, whereas
            // control-mode output uses octal \134. Accept both forms.
            if bytes.get(i + 1) == Some(&b'\\') {
                output.push(b'\\');
                i += 2;
                continue;
            }
            if i + 3 >= bytes.len()
                || !bytes[i + 1..i + 4]
                    .iter()
                    .all(|b| (b'0'..=b'7').contains(b))
            {
                return Err(bad("Invalid control-mode escape"));
            }
            let value = u16::from(bytes[i + 1] - b'0') * 64
                + u16::from(bytes[i + 2] - b'0') * 8
                + u16::from(bytes[i + 3] - b'0');
            if value > 255 {
                return Err(bad("Invalid control-mode byte"));
            }
            output.push(value as u8);
            i += 4;
        } else {
            output.push(bytes[i]);
            i += 1;
        }
    }
    Ok(output)
}
// Metadata and capture commands are queued together in the same control client.
fn screen_metadata(p: &mut Pane, line: &str) -> bool {
    let values = line
        .split_whitespace()
        .map(str::parse::<usize>)
        .collect::<std::result::Result<Vec<_>, _>>();
    let Ok(v) = values else {
        return false;
    };
    if v.len() != 14 || v[0] != p.width || v[1] != p.height {
        return false;
    }
    p.x = v[2];
    p.y = v[3];
    p.alternate = v[4] == 1;
    p.cursor = v[5] == 1;
    p.paste = v[6] == 1;
    p.insert = v[7] == 1;
    p.wrap = v[8] == 1;
    p.origin = v[9] == 1;
    p.keypad = v[10] == 1;
    p.application_cursor = v[11] == 1;
    p.top = v[12];
    p.bottom = v[13];
    true
}
fn bootstrap(p: &Pane, rows: &[String]) -> Result<Vec<u8>> {
    let mut out = b"\x1bc".to_vec();
    if p.alternate {
        out.extend_from_slice(b"\x1b[?1049h");
    }
    out.extend_from_slice(b"\x1b[?7l\x1b[H");
    for (i, line) in rows.iter().take(p.height).enumerate() {
        out.extend_from_slice(format!("\x1b[{};1H", i + 1).as_bytes());
        out.extend(unescape(line.as_bytes())?);
    }
    out.extend_from_slice(
        format!(
            "\x1b[0m\x1b[{};{}r\x1b[{};{}H",
            p.top + 1,
            p.bottom + 1,
            p.y + 1,
            p.x + 1
        )
        .as_bytes(),
    );
    for (mode, enabled) in [
        ("?25", p.cursor),
        ("?7", p.wrap),
        ("?2004", p.paste),
        ("4", p.insert),
        ("?1", p.application_cursor),
    ] {
        out.extend_from_slice(format!("\x1b[{mode}{}", if enabled { 'h' } else { 'l' }).as_bytes());
    }
    // Restore origin before cursor because CUP becomes relative to the scroll region.
    if p.origin {
        out.extend_from_slice(
            format!(
                "\x1b[?6h\x1b[{};{}H",
                p.y.saturating_sub(p.top) + 1,
                p.x + 1
            )
            .as_bytes(),
        );
    }
    out.extend_from_slice(if p.keypad { b"\x1b=" } else { b"\x1b>" });
    Ok(out)
}
fn frame(value: Value) -> std::result::Result<Bytes, std::io::Error> {
    Ok(Bytes::from(format!("{value}\n")))
}

pub async fn stream(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response> {
    let lease = lease(&app, &headers, &id).await?;
    if lease.created.elapsed() > Duration::from_secs(30)
        || lease.started.swap(true, Ordering::SeqCst)
    {
        return Err(conflict("Stream generation already used or expired"));
    }
    let mut current = pane(&app, &lease.pane).await?;
    if current.identity != lease.identity || !agent_matches(&lease).await {
        return Err(conflict("Target changed before attachment"));
    }
    let mut child = Command::new(&app.tmux)
        .args([
            "-C",
            "attach-session",
            "-f",
            "ignore-size",
            "-t",
            &current.session,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(internal)?;
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (sender, receiver) = mpsc::channel(64);
    tokio::spawn(async move {
        let _invalidate = Invalidate(lease.clone());
        let mut reader = BufReader::new(stdout);
        let mut raw_line = Vec::new();
        let mut block = 0;
        let mut inside = false;
        let mut marker = String::new();
        let mut captured = Vec::new();
        let mut pending = Vec::new();
        let mut ready = false;
        let mut check = tokio::time::interval(Duration::from_millis(700));
        let mut last_ping = Instant::now();
        // Command order forms a snapshot barrier: output before capture is discarded;
        // notifications after its block are forwarded exactly once.
        if stdin
            .write_all(format!("display-message -p -t {} '#{{pane_width}} #{{pane_height}} #{{cursor_x}} #{{cursor_y}} #{{alternate_on}} #{{cursor_flag}} #{{?bracket_paste_flag,1,0}} #{{insert_flag}} #{{wrap_flag}} #{{origin_flag}} #{{keypad_flag}} #{{keypad_cursor_flag}} #{{scroll_region_upper}} #{{scroll_region_lower}}' ; capture-pane -p -e -C -N -t {} ; capture-pane -p -P -C -t {}\n", lease.pane, lease.pane, lease.pane).as_bytes())
            .await
            .is_err()
        {
            return;
        }
        loop {
            let event = tokio::select! {
                _ = sender.closed() => break,
                _ = check.tick() => {
                    if lease.cancelled.load(Ordering::SeqCst) || !agent_matches(&lease).await || authorize(&headers, &app).is_err() { break; }
                    match pane(&app, &lease.pane).await {
                        Ok(next) if next.identity == lease.identity && next.width == current.width && next.height == current.height => {},
                        _ => { let _ = sender.try_send(frame(json!({"type":"closed","reason":"目标进程或远端尺寸已变化，请重新打开"}))); break; }
                    }
                    if !ready && lease.created.elapsed() > Duration::from_secs(15) { break; }
                    if last_ping.elapsed() > Duration::from_secs(5) { last_ping = Instant::now(); Some(json!({"type":"ping"})) } else { None }
                },
                count = reader.read_until(b'\n', &mut raw_line) => {
                    let Ok(count) = count else { break; };
                    if count == 0 || raw_line.len() > 2 * 1024 * 1024 { break; }
                    if raw_line.last() == Some(&b'\n') { raw_line.pop(); }
                    let raw = std::mem::take(&mut raw_line);
                    let line = String::from_utf8_lossy(&raw);
                    if inside {
                        if line == format!("%error {marker}") { break; }
                        if line == format!("%end {marker}") {
                            inside = false;
                            if block == 4 {
                                let Ok(mut data) = bootstrap(&current, &captured) else { break; };
                                data.extend_from_slice(&pending);
                                lease.active.store(true, Ordering::SeqCst); ready = true;
                                Some(json!({"type":"ready","cols":current.width,"rows":current.height,"data":STANDARD.encode(data)}))
                            } else { None }
                        } else {
                            if block == 2 {
                                if !screen_metadata(&mut current, &line) { break; }
                            } else if block == 3 { captured.push(line.into_owned()); }
                            else if block == 4 { match unescape(&raw) { Ok(data) => pending.extend(data), Err(_) => break } }
                            None
                        }
                    } else if let Some(value) = line.strip_prefix("%begin ") { block += 1; marker = value.into(); inside = true; None }
                    else if line.starts_with("%exit") { break; }
                    else if let Some(value) = raw.strip_prefix(format!("%output {} ",lease.pane).as_bytes()) {
                        if ready { match unescape(value) { Ok(data) => Some(json!({"type":"data","data":STANDARD.encode(data)})), Err(_) => break } } else { None }
                    } else { None }
                }
            };
            if let Some(event) = event
                && sender.try_send(frame(event)).is_err()
            {
                break;
            }
        }
        let _ = child.kill().await;
        let _ = child.wait().await;
    });
    Response::builder()
        .header("Content-Type", "application/x-ndjson")
        .header("Cache-Control", "no-store")
        .body(Body::from_stream(ReceiverStream::new(receiver)))
        .map_err(internal)
}
#[derive(Deserialize)]
pub struct Input {
    sequence: u64,
    request_id: String,
    kind: String,
    #[serde(default)]
    key: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    confirm_multiline: bool,
}
fn validate_text(text: &str) -> Result<()> {
    if text.is_empty()
        || text.len() > 16384
        || text
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\t')
    {
        return Err(bad(
            "Text contains unsupported terminal controls or exceeds 16 KiB",
        ));
    }
    Ok(())
}
fn key(name: &str) -> Result<&str> {
    match name {
        "Up" | "Down" | "Left" | "Right" | "Enter" | "Escape" | "Tab" | "BTab" | "Space"
        | "BSpace" | "DC" | "Home" | "End" | "PPage" | "NPage" | "C-c" | "C-d" => Ok(name),
        _ => Err(bad("Unsupported key")),
    }
}
pub async fn input(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(request): Json<Input>,
) -> Result<Json<Value>> {
    let lease = lease(&app, &headers, &id).await?;
    let mut state = lease.writes.lock().await;
    if !lease.active.load(Ordering::SeqCst) {
        return Err(conflict("No active terminal stream"));
    }
    let current = pane(&app, &lease.pane).await?;
    if current.identity != lease.identity || !agent_matches(&lease).await {
        lease.cancelled.store(true, Ordering::SeqCst);
        return Err(conflict("Foreground process changed; reselect target"));
    }
    match request.kind.as_str() {
        "key" => {
            key(&request.key)?;
        }
        "paste" | "text" => {
            validate_text(&request.text)?;
            if request.text.contains('\n') && (!request.confirm_multiline || !current.paste) {
                return Err(bad(
                    "Multiline requires bracketed-paste mode and explicit confirmation",
                ));
            }
        }
        _ => return Err(bad("Unsupported terminal action")),
    }
    // Consume before side effects. An ambiguous failure is never replayable.
    state.claim(request.sequence, request.request_id)?;
    if lease.cancelled.load(Ordering::SeqCst) || !lease.active.load(Ordering::SeqCst) {
        return Err(conflict("Connection generation ended"));
    }
    let result = if request.kind == "key" {
        tmux(&app, &["send-keys", "-t", &lease.pane, "--", &request.key])
            .await
            .map(|_| ())
    } else if request.kind == "text" && !request.text.contains('\n') {
        tmux(
            &app,
            &["send-keys", "-t", &lease.pane, "-l", "--", &request.text],
        )
        .await
        .map(|_| ())
    } else {
        paste(&app, &lease, &request.text, current.paste).await
    };
    if let Err(error) = result {
        lease.cancelled.store(true, Ordering::SeqCst);
        return Err(error);
    }
    Ok(Json(
        json!({"accepted":true,"sequence":state.sequence,"meaning":"delivered-to-terminal-not-agent-acknowledgement"}),
    ))
}
async fn paste(app: &App, lease: &Lease, text: &str, bracketed: bool) -> Result<()> {
    let buffer = format!("agentmux-{}", uuid::Uuid::new_v4().simple());
    let mut child = Command::new(&app.tmux)
        .args(["load-buffer", "-b", &buffer, "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(internal)?;
    let result = async {
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(text.as_bytes()).await.map_err(internal)?;
        drop(stdin);
        if !tokio::time::timeout(Duration::from_secs(5), child.wait())
            .await
            .map_err(internal)?
            .map_err(internal)?
            .success()
        {
            return Err(internal("Unable to stage terminal paste"));
        }
        if pane(app, &lease.pane).await?.identity != lease.identity
            || !agent_matches(lease).await
            || lease.cancelled.load(Ordering::SeqCst)
            || !lease.active.load(Ordering::SeqCst)
        {
            return Err(conflict("Target changed while preparing paste"));
        }
        if text.contains('\n') {
            // -F evaluates a tmux format (never a shell). The branch is built
            // only from our UUID buffer and a validated numeric pane ID.
            // Checking and pasting in the tmux command queue avoids a mode-off
            // race that could otherwise turn embedded newlines into Enter.
            let command = format!("paste-buffer -d -p -r -b {buffer} -t {}", lease.pane);
            let result = tmux(
                app,
                &[
                    "if-shell",
                    "-F",
                    "-t",
                    &lease.pane,
                    "#{bracket_paste_flag}",
                    &command,
                    "display-message -p agentmux-paste-mode-changed",
                ],
            )
            .await?;
            if result.contains("agentmux-paste-mode-changed") {
                return Err(conflict(
                    "Bracketed paste mode changed; text was not pasted",
                ));
            }
            return Ok(());
        }
        let mut args = vec!["paste-buffer", "-d", "-b", &buffer, "-t", &lease.pane];
        if bracketed {
            args.push("-p");
        }
        tmux(app, &args).await?;
        Ok(())
    }
    .await;
    let _ = tmux(app, &["delete-buffer", "-b", &buffer]).await;
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ambiguous_writes_cannot_be_replayed_or_reordered() {
        let mut state = WriteState::default();
        let first = uuid::Uuid::new_v4().to_string();
        state.claim(1, first.clone()).unwrap(); // Claimed even if the transport later fails.
        assert!(state.claim(1, first.clone()).is_err());
        assert!(state.claim(2, first).is_err()); // Changing only the sequence is still a duplicate.
        assert!(state.claim(3, uuid::Uuid::new_v4().to_string()).is_err());
        assert!(state.claim(2, "not-a-request-id".into()).is_err());
        assert_eq!(state.sequence, 1);
        state.claim(2, uuid::Uuid::new_v4().to_string()).unwrap();
        assert_eq!(state.ids.len(), 2);
    }
    #[test]
    fn control_mode_bytes_are_lossless() {
        assert_eq!(
            unescape(r"\033[31m中文\134x\015\012".as_bytes()).unwrap(),
            b"\x1b[31m\xe4\xb8\xad\xe6\x96\x87\\x\r\n"
        );
        assert!(unescape(br"\777").is_err());
        assert!(unescape(br"\0").is_err());
    }
    #[test]
    fn preserves_split_utf8_and_capture_backslashes() {
        let mut bytes = unescape(&[0xe4, 0xb8]).unwrap();
        bytes.extend(unescape(&[0xad, 0xe6, 0x96, 0x87]).unwrap());
        assert_eq!(String::from_utf8(bytes).unwrap(), "中文");
        assert_eq!(unescape(br"C:\\work\\draft").unwrap(), br"C:\work\draft");
    }
    #[test]
    fn restores_screen_modes_cursor_region_and_unicode() {
        let mut p = Pane {
            identity: Identity {
                server: "s".into(),
                pane: "%1:p".into(),
                process: "p".into(),
                command: "unknown".into(),
            },
            session: "$1".into(),
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            alternate: false,
            cursor: true,
            paste: false,
            insert: false,
            wrap: true,
            origin: false,
            keypad: false,
            application_cursor: false,
            top: 0,
            bottom: 23,
        };
        assert!(screen_metadata(&mut p, "80 24 3 5 1 1 1 0 1 0 1 1 2 20"));
        assert!(!screen_metadata(&mut p, "81 24 3 5 1 1 1 0 1 0 1 1 2 20"));
        let data = bootstrap(
            &p,
            &[
                r"\033[32m菜单\\path".into(),
                "%end not-a-protocol-marker".into(),
            ],
        )
        .unwrap();
        let result = String::from_utf8(data).unwrap();
        assert!(result.contains("\x1b[?1049h"));
        assert!(result.contains("\x1b[3;21r\x1b[6;4H"));
        assert!(result.contains("\x1b[?2004h"));
        assert!(result.contains("\x1b[?1h"));
        assert!(result.contains("菜单\\path"));
    }
    #[test]
    fn rejects_injection_but_preserves_unicode_drafts() {
        assert!(key("Enter; kill-server").is_err());
        assert!(key("y").is_err());
        assert!(validate_pane("%1;kill-server").is_err());
        assert!(validate_text("中文\n第二行\t🙂").is_ok());
        assert!(validate_text("\x1b[201~\rcommand").is_err());
        assert!(validate_text("\x7f").is_err());
    }
}
