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
    sizes: Mutex<HashMap<String, SizeLease>>,
    journal: Option<PathBuf>,
}
struct Lease {
    generation: String,
    pane: String,
    owner: String,
    identity: Identity,
    created: Instant,
    active: AtomicBool,
    started: AtomicBool,
    cancelled: AtomicBool,
    writes: Mutex<WriteState>,
    agent: Option<(u32, String)>,
    resize_tx: mpsc::Sender<ResizeRequest>,
    resize_rx: Mutex<Option<mpsc::Receiver<ResizeRequest>>>,
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
    // Restore even already-cancelled generations before pruning them. A close
    // request and immediate navigation can arrive on different SSH channels.
    for old in leases
        .values()
        .filter(|lease| lease.owner == owner(&headers))
    {
        old.cancelled.store(true, Ordering::SeqCst);
        old.active.store(false, Ordering::SeqCst);
        let _writes = old.writes.lock().await;
        release_size(&app, old).await;
    }
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
    let id = uuid::Uuid::new_v4().to_string();
    let (resize_tx, resize_rx) = mpsc::channel(1);
    leases.insert(
        id.clone(),
        Arc::new(Lease {
            generation: id.clone(),
            pane: request_pane(&current),
            owner: owner(&headers),
            identity: current.identity.clone(),
            created: Instant::now(),
            active: AtomicBool::new(false),
            started: AtomicBool::new(false),
            cancelled: AtomicBool::new(false),
            agent,
            writes: Mutex::new(WriteState::default()),
            resize_tx,
            resize_rx: Mutex::new(Some(resize_rx)),
        }),
    );
    Ok(Json(
        json!({"generation":id,"cols":current.width,"rows":current.height,"command":current.identity.command,"capabilities":{"key":true,"paste":true,"multiline_paste":current.paste,"resize":true}}),
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
    release_size(&app, &lease).await;
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

struct ResizeRequest {
    enabled: bool,
    cols: usize,
    rows: usize,
    reply: tokio::sync::oneshot::Sender<Result<()>>,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
struct WindowSize {
    id: String,
    cols: usize,
    rows: usize,
    layout: String,
    policy: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
struct SizeLease {
    generation: String,
    server: String,
    pane: String,
    pane_identity: String,
    owner: String,
    original: WindowSize,
    applied: WindowSize,
}
impl Manager {
    pub fn with_journal(state: &FsPath) -> Self {
        Self {
            journal: Some(state.join("terminal-sizes.json")),
            ..Self::default()
        }
    }
}
async fn window_size(app: &App, target: &str) -> Result<WindowSize> {
    let value = tmux(app, &["display-message", "-p", "-t", target,
        "#{window_id}\t#{window_width}\t#{window_height}\t#{window_layout}\t#{window_zoomed_flag}"]).await?;
    let fields: Vec<_> = value.trim().split('\t').collect();
    if fields.len() != 5 || !fields[0].starts_with('@') || fields[4] != "0" {
        return Err(conflict("请先在 Mac 退出窗格放大模式，再开启尺寸跟随"));
    }
    let policy = tmux(
        app,
        &["show-options", "-w", "-v", "-t", fields[0], "window-size"],
    )
    .await?;
    Ok(WindowSize {
        id: fields[0].into(),
        cols: fields[1].parse().map_err(bad)?,
        rows: fields[2].parse().map_err(bad)?,
        layout: fields[3].into(),
        policy: if policy.trim().is_empty() {
            None
        } else {
            Some(policy.trim().into())
        },
    })
}
async fn save_sizes(app: &App, sizes: &HashMap<String, SizeLease>) -> Result<()> {
    if let Some(path) = &app.terminal.journal {
        let temp = path.with_extension("tmp");
        tokio::fs::write(&temp, serde_json::to_vec(sizes).map_err(internal)?)
            .await
            .map_err(internal)?;
        tokio::fs::rename(temp, path).await.map_err(internal)?;
    }
    Ok(())
}
async fn restore_size(app: &App, saved: &SizeLease) -> Result<()> {
    let current = pane(app, &saved.pane).await?;
    if current.identity.server != saved.server || current.identity.pane != saved.pane_identity {
        return Ok(());
    }
    // Never overwrite a layout/size policy edited on the Mac since our last change.
    if window_size(app, &saved.pane).await? != saved.applied {
        return Ok(());
    }
    let original = &saved.original;
    tmux(
        app,
        &[
            "resize-window",
            "-t",
            &original.id,
            "-x",
            &original.cols.to_string(),
            "-y",
            &original.rows.to_string(),
        ],
    )
    .await?;
    tmux(
        app,
        &["select-layout", "-t", &original.id, &original.layout],
    )
    .await?;
    if let Some(policy) = &original.policy {
        tmux(
            app,
            &[
                "set-option",
                "-w",
                "-t",
                &original.id,
                "window-size",
                policy,
            ],
        )
        .await?;
    } else {
        tmux(
            app,
            &["set-option", "-w", "-u", "-t", &original.id, "window-size"],
        )
        .await?;
    }
    Ok(())
}
pub async fn recover_sizes(app: &App) {
    let Some(path) = &app.terminal.journal else {
        return;
    };
    let Ok(data) = tokio::fs::read(path).await else {
        return;
    };
    let Ok(mut sizes) = serde_json::from_slice::<HashMap<String, SizeLease>>(&data) else {
        return;
    };
    let mut failed = HashMap::new();
    for (key, saved) in sizes.drain() {
        if restore_size(app, &saved).await.is_err() {
            failed.insert(key, saved);
        }
    }
    let _ = save_sizes(app, &failed).await;
    *app.terminal.sizes.lock().await = failed;
}
async fn release_size(app: &App, lease: &Lease) {
    let mut sizes = app.terminal.sizes.lock().await;
    let keys: Vec<_> = sizes
        .iter()
        .filter(|(_, saved)| saved.generation == lease.generation)
        .map(|(key, _)| key.clone())
        .collect();
    for key in keys {
        if let Some(saved) = sizes.get(&key)
            && restore_size(app, saved).await.is_ok()
        {
            sizes.remove(&key);
        }
    }
    let _ = save_sizes(app, &sizes).await;
}
async fn size_was_changed_externally(app: &App, lease: &Lease) -> bool {
    let mut sizes = app.terminal.sizes.lock().await;
    let key = sizes
        .iter()
        .find(|(_, saved)| saved.generation == lease.generation)
        .map(|(key, _)| key.clone());
    if let Some(key) = key {
        let changed = window_size(app, &lease.pane)
            .await
            .map_or(true, |current| current != sizes[&key].applied);
        if changed {
            sizes.remove(&key);
            let _ = save_sizes(app, &sizes).await;
            return true;
        }
    }
    false
}
async fn resize_window(
    app: &App,
    lease: &Lease,
    enabled: bool,
    cols: usize,
    rows: usize,
) -> Result<()> {
    if !enabled {
        release_size(app, lease).await;
        return Ok(());
    }
    let current = pane(app, &lease.pane).await?;
    if current.identity != lease.identity || lease.cancelled.load(Ordering::SeqCst) {
        return Err(conflict("会话已变化，请重新打开"));
    }
    let mut sizes = app.terminal.sizes.lock().await;
    let before = window_size(app, &lease.pane).await?;
    let key = format!("{}:{}", lease.identity.server, before.id);
    if let Some(saved) = sizes.get(&key) {
        if saved.generation != lease.generation {
            return Err(conflict("另一个连接正在调整此窗口，当前使用固定尺寸"));
        }
        if saved.applied != before {
            sizes.remove(&key);
            save_sizes(app, &sizes).await?;
            return Err(conflict("Mac 已调整窗口，手机已停止尺寸跟随"));
        }
    } else {
        sizes.insert(
            key.clone(),
            SizeLease {
                generation: lease.generation.clone(),
                server: lease.identity.server.clone(),
                pane: lease.pane.clone(),
                pane_identity: lease.identity.pane.clone(),
                owner: lease.owner.clone(),
                original: before.clone(),
                applied: before.clone(),
            },
        );
        save_sizes(app, &sizes).await?;
    }
    // The phone displays one pane, not the whole window. Reserve the space
    // occupied by its siblings before sizing the target pane to the viewport.
    let window_cols = cols + before.cols.saturating_sub(current.width);
    let window_rows = rows + before.rows.saturating_sub(current.height);
    tmux(
        app,
        &[
            "resize-window",
            "-t",
            &before.id,
            "-x",
            &window_cols.to_string(),
            "-y",
            &window_rows.to_string(),
        ],
    )
    .await?;
    // resize-window may distribute its delta across siblings. Correct the
    // target explicitly, keeping the split tree and all other panes alive.
    sizes.get_mut(&key).unwrap().applied = window_size(app, &lease.pane).await?;
    save_sizes(app, &sizes).await?;
    let resized = tmux(
        app,
        &[
            "resize-pane",
            "-t",
            &lease.pane,
            "-x",
            &cols.to_string(),
            "-y",
            &rows.to_string(),
        ],
    )
    .await;
    sizes.get_mut(&key).unwrap().applied = window_size(app, &lease.pane).await?;
    save_sizes(app, &sizes).await?;
    resized?;
    Ok(())
}
fn snapshot_command(pane: &str) -> String {
    format!(
        "display-message -p -t {pane} '#{{pane_width}} #{{pane_height}} #{{cursor_x}} #{{cursor_y}} #{{alternate_on}} #{{cursor_flag}} #{{?bracket_paste_flag,1,0}} #{{insert_flag}} #{{wrap_flag}} #{{origin_flag}} #{{keypad_flag}} #{{keypad_cursor_flag}} #{{scroll_region_upper}} #{{scroll_region_lower}}' ; capture-pane -p -e -C -N -t {pane} ; capture-pane -p -P -C -t {pane}\n"
    )
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
    let mut resize_rx = lease
        .resize_rx
        .lock()
        .await
        .take()
        .ok_or_else(|| conflict("Stream already started"))?;
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
        let mut resize_reply: Option<tokio::sync::oneshot::Sender<Result<()>>> = None;
        let mut resize_started = Instant::now();
        let mut check = tokio::time::interval(Duration::from_millis(700));
        let mut last_ping = Instant::now();
        // Command order forms a snapshot barrier: output before capture is discarded;
        // notifications after its block are forwarded exactly once.
        if stdin
            .write_all(snapshot_command(&lease.pane).as_bytes())
            .await
            .is_err()
        {
            return;
        }
        loop {
            let event = tokio::select! {
                _ = sender.closed() => break,
                request = resize_rx.recv(), if ready => {
                    let Some(request) = request else { break; };
                    match resize_window(&app, &lease, request.enabled, request.cols, request.rows).await {
                        Ok(()) => {
                            let Ok(next) = pane(&app, &lease.pane).await else { break; };
                            if next.identity != lease.identity { break; }
                            current = next;
                            ready = false; block = 1; captured.clear(); pending.clear();
                            resize_started = Instant::now();
                            resize_reply = Some(request.reply);
                            if stdin.write_all(snapshot_command(&lease.pane).as_bytes()).await.is_err() { break; }
                            None
                        }
                        Err(error) => {
                            let reason = error.1.clone();
                            let _ = request.reply.send(Ok(()));
                            Some(json!({"type":"resize_rejected","reason":reason}))
                        }
                    }
                },
                _ = check.tick() => {
                    if lease.cancelled.load(Ordering::SeqCst) || !agent_matches(&lease).await || authorize(&headers, &app).is_err() { break; }
                    match pane(&app, &lease.pane).await {
                        Ok(next) if next.identity == lease.identity && next.width == current.width && next.height == current.height => {},
                        _ => { let _ = sender.try_send(frame(json!({"type":"closed","reason":"目标进程或远端尺寸已变化，请重新打开"}))); break; }
                    }
                    if size_was_changed_externally(&app, &lease).await {
                        let _ = sender.try_send(frame(json!({"type":"closed","reason":"Mac 已调整窗口布局，手机已停止尺寸跟随，请重新打开会话"})));
                        break;
                    }
                    if !ready && (if resize_reply.is_some() { resize_started.elapsed() } else { lease.created.elapsed() }) > Duration::from_secs(15) { break; }
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
                                let resized = resize_reply.is_some();
                                if let Some(reply) = resize_reply.take() { let _ = reply.send(Ok(())); }
                                Some(json!({"type":if resized { "resized" } else { "ready" },"cols":current.width,"rows":current.height,"data":STANDARD.encode(data)}))
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
        release_size(&app, &lease).await;
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
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    cols: usize,
    #[serde(default)]
    rows: usize,
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
        "resize" => {
            if request.enabled
                && (!(2..=1000).contains(&request.cols) || !(2..=1000).contains(&request.rows))
            {
                return Err(bad("Terminal grid must be between 2 and 1000 cells"));
            }
        }
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
    let result = if request.kind == "resize" {
        let (reply, receive) = tokio::sync::oneshot::channel();
        lease
            .resize_tx
            .send(ResizeRequest {
                enabled: request.enabled,
                cols: request.cols,
                rows: request.rows,
                reply,
            })
            .await
            .map_err(|_| conflict("Terminal stream ended"))?;
        tokio::time::timeout(Duration::from_secs(20), receive)
            .await
            .map_err(|_| conflict("Resize timed out; reopen terminal"))?
            .map_err(|_| conflict("Terminal stream ended during resize"))?
    } else if request.kind == "key" {
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
