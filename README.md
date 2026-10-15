# AgentMux

Rust macOS service + SwiftUI iOS client. Version 0.6 development build.

## Features

- Connect with an existing Mac SSH login (password or OpenSSH private key); verify the host fingerprint, then discover AgentMux and enroll automatically. No QR required. Credentials are saved in iOS Keychain.
- Discover Codex, Claude Code and Pi on the selected tmux server, plus explicitly select any unknown pane in generic terminal mode.
- Live SwiftTerm TUI above one adjustable Text / Micro / Glide workbench. Local per-session drafts, IME-aware direct input, explicit keys and local viewport browsing. Native iOS 26 glass controls with material/accessibility fallbacks.
- Rich messages with Markdown, copyable code blocks, formatted CLI commands, collapsible tool cards, model selection, stop controls, approvals and question forms.
- New native sessions use Codex app-server, Claude Code bidirectional stream-json and Pi JSONL RPC.
- Manually started tmux Agents stay in their original processes. Navigate unknown keyboard-driven menus through live terminal output and explicit keys; native same-session capabilities optionally reduce steps.
- Optional Codex, Claude Code and Pi plugins expose native controls for existing sessions. Their activation and capabilities differ; see [plugin setup](docs/PLUGINS.md).
- Revocable per-device credentials saved in iOS Keychain and hashed on the Mac.
- iOS settings for default directory and authorized roots, revision conflicts and atomic configuration updates.
- File listing and upload/download up to 8 MiB, without overwrite; capability-confined file access.
- Send photos/files from the chat paperclip: private Mac `/tmp` uploads are forwarded to the selected original Agent and displayed as attachment cards.
- Unsigned arm64 device IPA build script.

## Quick start: Mac → SSH → iPhone

Requirements: Rust, tmux, installed/logged-in Codex / Claude Code / Pi. iOS 17+; Xcode and XcodeGen for builds.

```sh
cargo build --release
# Run from the project directory you want to access from your phone.
./target/release/agentmuxd
```

On first launch, the daemon creates `agentmux.json` with private permissions, authorizes the current directory, and detects Codex / Claude / Pi executables on `PATH`. Missing agents retain their command names and can be installed later. Existing configuration is preserved; malformed configuration reports an error. To expose another project, launch the binary from that project's directory. You can edit `agentmux.json` locally to authorize additional existing directories or customize executable paths, then restart the daemon. `agentmux.example.json` remains available as a reference.

Enable **System Settings → General → Sharing → Remote Login** on the Mac. In the iOS app, choose **通过 SSH 连接 Mac**, enter the Mac hostname/IP, SSH port (default 22), username, and password or private key. Verify the displayed SSH fingerprint, then choose **信任主机并连接**. The app discovers the running daemon and connects automatically through the same SSH connection; no `agentmuxd pair` command or open port 9848 is needed for this mode. SSH command execution and local TCP forwarding must be allowed for the account.

The daemon publishes a private discovery file at `~/Library/Application Support/AgentMux/service.json`. The app uses SSH to locate the binary and run `agentmuxd connect`, which checks the loopback service on port 9847 and creates a revocable device credential. The administrator token stays on the Mac. The SSH fingerprint is pinned for future connections. Ed25519 OpenSSH keys, including passphrase-protected keys, are supported; RSA compatibility depends on the SSH server accepting the library's RSA signature algorithm. SSH agent forwarding and hardware-backed keys are not implemented. `AGENTMUX_DISCOVERY` overrides the discovery file path; a custom path must also be available in the remote SSH environment.

## Agent conversations

The app searches every session on the configured tmux server. Recognized Agents appear automatically; **+ → 选择任意 tmux pane** exposes unknown programs and shells for explicit target selection. No replacement process is started. Discovery is independent of file roots; files and new-session creation remain restricted to approved roots.

Opening a tmux session shows its live terminal through SwiftTerm. The bottom workbench switches between **文本 / Micro / 滑控** without leaving the screen. Text has a local draft editor and a separate direct-terminal keyboard. Native **发送** is available only when a linked adapter advertises same-session message support; otherwise **填入终端** pastes without clearing existing text or appending Enter. Enter remains a separately labeled key. Multiline paste is refused if tmux cannot positively report bracketed-paste mode, and still requires confirmation when supported.

Micro provides explicit navigation/Enter/Esc/Tab/Space and up to six configurable session shortcuts. Glide explicitly separates local viewport browsing from remote arrow keys. New connections require target confirmation; stale streams, foreground-process changes, external resize and uncertain writes stop input instead of replaying. Mac keyboard input is not locked out. See [implementation and state design](docs/TERMINAL-WORKBENCH.md) and [verification/limitations](docs/TERMINAL-VERIFICATION.md).

Native enhancements, history and attachments remain accessible. Parsed menus are no longer a prerequisite or semantic approval fallback. Daemon-managed sessions without tmux panes retain their structured UI and do not expose fake terminal controls.

History is independent of control. Claude runtime metadata can identify its current log; otherwise select the actual current conversation from project-scoped records. AgentMux does not guess from the most recently modified log. Selecting history does not resume, replace, or change the running Agent.

For full native controls, tap **+** to create a conversation using the Mac's configured Agent login. These sessions are owned by the daemon and are not tmux panes. Codex model selection applies to the next turn. Supported permissions and user questions appear as forms; unknown request types are never automatically approved. A daemon restart ends its managed child processes, so finish active tasks before restarting.

Pi can use the public SDK in the **same existing process**. Load the supplied extension:

```sh
pi -e /absolute/path/to/agentmux/integrations/pi/agentmux.ts
```

For loading into an already-running Pi with `/reload`, Codex/Claude plugins, capability details and protocol research, see [plugin setup](docs/PLUGINS.md) and [Agent integration](docs/AGENT-INTEGRATION.md).

## Chat attachments

Tap the paperclip to select photos or files, optionally add a caption, then send. Uploads default to `/tmp/agentmux-uploads-<uid>-<state-hash>/<attachment-id>/content/<filename>` on the Mac; they do not require adding `/tmp` to the file-browser roots. Only authenticated clients can upload/download receipts. The private directory is separate for each daemon state; files use mode `0600`.

The selected Agent receives the caption and actual uploaded paths in one message. The terminal workbench uploads privately and inserts paths into the local draft; filling the terminal is a separate explicit action. Agents can read ordinary files through their own tools. Native managed sessions receive images through Codex local-image input, Claude image blocks, or Pi RPC images. Updated plugins use Codex queue images, Pi SDK image content, and Claude's `read_attachment` MCP tool. Actual image interpretation depends on the provider/model. This does not simulate a terminal's interactive attachment picker.

Limits: six attachments per message, 8 MiB per file, 24 MiB per message; photos are resized to at most 2560 pixels and converted to JPEG. The service store holds at most 512 uploads/256 MiB and refuses further uploads when full. Temporary files may be removed by the OS; clean the service's upload directory when no Agent still needs those files. They are not durable document storage.

Drafts belong to their conversation and survive in-app session switching. Upload retries reuse the attachment ID and message retries reuse the request ID; changed payloads cannot overwrite an existing receipt. Both the Mac daemon and iOS app must be updated for chat uploads; reload/update provider plugins for native image forwarding.

## Connection and local configuration

Camera and photo QR pairing have been removed from iOS. Use your existing Mac SSH account. Earlier QR transport code remains for compatibility tests; it is not an app connection option. `AGENTMUX_SSH_DISABLED=1` disables the legacy dedicated listener on port 9848.

The HTTP API stays loopback-only, normally port 9847. `AGENTMUX_API_PORT` selects another local port; SSH discovery reports it automatically. The discovery file and administrator token must remain private. The daemon generates its local state in `.agentmux/`; `AGENTMUX_STATE` and `AGENTMUX_CONFIG` override the state and configuration locations. Initial provider login is performed on the Mac.

## Build unsigned IPA

```sh
sh scripts/build-unsigned-ipa.sh
```

Outputs `dist/AgentMux-unsigned.ipa` and SHA-256 sidecar. This is an iphoneos/arm64 Release app with signing disabled. A normal iPhone requires re-signing with your certificate/provisioning workflow. The generated unsigned IPA contains no signing identity or developer account.

GitHub Actions runs the same build for iOS changes pushed to `main` and pull requests. To build manually, open [Build iOS app](https://github.com/xbunax/agentmux/actions/workflows/ios.yml), select **Run workflow**, and choose a branch. Download `AgentMux-unsigned-<run number>` from the completed run's **Artifacts** section; it contains the IPA and checksum. Extract both files into one directory and run `shasum -a 256 -c AgentMux-unsigned.ipa.sha256` to verify the download. Artifacts and build logs are retained for 14 days. No Apple signing secrets are required.

## Verification commands

```sh
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
python3 scripts/test-terminal-api.py
python3 scripts/test-terminal-stream.py
python3 scripts/smoke-test.py
python3 scripts/test-tmux-agents.py
python3 scripts/test-manual-tmux.py
python3 scripts/test-attachments.py
node scripts/test-pi-extension.mjs
# Optional installed Pi SDK loading check; no model request:
python3 scripts/test-pi-load.py
# Real offline Pi menu test; no model request:
python3 scripts/test-real-pi-tui.py
python3 scripts/test-real-pi-tui.py --narrow
python3 scripts/test-real-pi-tui.py --sdk-dialogs
# Packaged Claude/Codex plugin protocol and Rust API fixtures:
python3 scripts/package-plugins.py
npm ci --ignore-scripts --prefix dist/plugins/agentmux-claude
node scripts/test-plugin-protocols.mjs
python3.13 -m venv build/test-venv
build/test-venv/bin/pip install paramiko==3.5.1
build/test-venv/bin/python scripts/test-ssh-agents.py
# Uses real installed agents and sends a short provider request (may incur cost):
build/test-venv/bin/python scripts/test-ssh-agents.py --live
```

The service/tmux/native-agent/normal-SSH tests use independent local ports; older QR probe scripts still require their configured ports. Tests use temporary roots and credentials; tmux smoke tests use an isolated socket and `/dev/null` tmux config. Fake protocol fixtures are not proof of provider compatibility.

For actual iOS simulator layout captures (offline fixture data, isolated simulator, no real Agent connection):

```sh
python3 scripts/preview-ios-ui.py --screen text --output build/ui-text.png
python3 scripts/preview-ios-ui.py --screen micro --output build/ui-micro.png
python3 scripts/preview-ios-ui.py --screen glide --output build/ui-glide.png
python3 scripts/preview-ios-ui.py --screen keyboard --output build/ui-keyboard.png
python3 scripts/preview-ios-ui.py --screen attachments --output build/ui-attachments.png
python3 scripts/preview-ios-ui.py --screen commands --output build/ui-commands.png
# Pure Foundation presentation regressions:
swiftc -module-cache-path build/swift-module-cache ios/Sources/MessagePresentation.swift tests/MessagePresentationProbe.swift -o build/MessagePresentationProbe
build/MessagePresentationProbe
```

Preview screens also include `sessions`, `chat` and `menu`; `--light` checks light appearance. These screenshots establish actual simulator layout, not real-device interaction. The iOS Actions workflow uploads workbench previews for push/PR builds; manual runs can enable `capture_previews`.

The Swift probe compiles **the exact SSHTransport.swift used by iOS** for Mac-side interoperability tests:

```sh
swift build --scratch-path build/swift-probe --product SSHProbe
# Generate a fresh QR first; this consumes it and revokes its test device afterward.
AGENTMUX_PAIR_JSON="$PWD/.agentmux/pair.json" build/swift-probe/debug/SSHProbe
```

To test normal SSH discovery without QR or the port-9848 listener:

```sh
cargo build
swift build --scratch-path build/ssh-login-probe --disable-build-manifest-caching --product SSHProbe
build/test-venv/bin/python scripts/test-ssh-login.py
```

This starts an isolated Paramiko SSH server and checks password and encrypted Ed25519 authentication, service discovery, automatic enrollment, forwarding, reconnect, revocation, and rejection of changed host keys. It does not replace real-iPhone testing of login, interaction, and background transitions.

See `docs/VERIFICATION.md` for actual verification evidence and device limitations, when available. A successful device build or desktop SSH test is not an iPhone end-to-end test.

## Limitations

- Structured snapshots are polled, not WebSocket replay; retained in daemon memory. No SQLite history or automatic managed-process resume yet.
- Message IDs prevent resubmission within a running managed session. A timed-out action may have executed; inspect state before retrying. No persistent cross-restart deduplication.
- Existing sessions use live terminal transport without requiring provider plugins. Native plugins require provider activation: Codex trusted hooks/shared daemon; Claude explicit development Channel opt-in; Pi extension loading. Installing a plugin does not hot-enable every already-running process.
- Transcript discovery uses provider default layouts and environment overrides. Ambiguous records require explicit selection.
- Terminal bootstrap is not a complete serialization of tmux state: pre-attach history, inactive buffers, graphics and uncommon modes need further validation. Old tmux versions without `bracket_paste_flag` reject multiline paste. Mobile/Mac concurrent input cannot be made exclusive by this service. Legacy `/input` and `/interrupt` endpoints now return HTTP 410; update daemon and iOS together.
- No launchd installer, automatic updates, APNs, Android or multi-user roles.
- Mobile background suspension closes/invalidates transports; reconnect occurs on the next foreground request. Agents continue while the daemon remains running.

## Security

Single trusted-user service. SSH enrollment grants Agent control as the Mac user. Directory filters are **not an Agent sandbox**: tools and existing processes may access other files. Avoid sensitive files in approved roots. Secrets are not content-classified on download. SSH private host keys never leave the Mac.

Keep the discovery file private: it contains the local administrator credential and is created with mode `0600`. In normal SSH mode, removing a device revokes its AgentMux API credential; the Mac SSH account can still authenticate and enroll again until its SSH access is removed separately.

Remote clients cannot change agent executable paths or exceed roots loaded at startup. Narrowed roots persist and become the new ceiling after restart. Device removal immediately denies HTTP actions and new SSH authentications; it does not forcibly terminate an already-open SSH transport, which remains limited to the now-auth-denied API.

## API

Authenticated APIs use `Authorization: Bearer <device credential or local administrator token>`.

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/pair/issue` | Local-admin-only QR ticket creation |
| POST | `/v1/pair/complete` | Exchange SSH-authenticated single-use ticket |
| GET / DELETE | `/v1/devices` / `/v1/devices/{id}` | Devices / revoke |
| POST | `/v1/devices` | Local-admin-only enrollment for authenticated SSH discovery |
| GET / PUT | `/v1/settings` | Configuration |
| GET / POST | `/v1/managed` | Structured session list / create |
| GET | `/v1/managed/{id}` | Structured snapshot |
| POST | `/v1/managed/{id}/actions` | Message, model, command, abort, approval |
| GET | `/v1/plugins` | Active native plugin connections, including externally started processes |
| GET | `/v1/plugins/{id}/chat` | Native plugin history, commands, capabilities and linked tmux menu |
| POST | `/v1/plugins/{id}/actions` | PID-bound native actions or explicitly routed original-pane actions |
| GET / POST | `/v1/sessions` | Running Agent panes across all tmux sessions / legacy create |
| GET | `/v1/sessions/{id}/chat` | Structured history, conversations and capabilities |
| POST | `/v1/sessions/{id}/actions` | PID-bound message, menu navigation/confirmation, Escape and optional history selection; Pi SDK actions when loaded |
| GET | `/v1/sessions/{id}/output` | Legacy terminal snapshot; not used by iOS |
| POST | `/v1/sessions/{id}/input` / `interrupt` | Legacy terminal control; not used by iOS |
| GET | `/v1/files?path=...` | Directory list |
| GET / PUT | `/v1/file?path=...` | File transfer |
| PUT / GET | `/v1/attachments/{uuid}?name=...` | Private temporary chat upload / authenticated download (name required for PUT only) |

Message actions accept `attachments: ["<receipt UUID>"]`; raw native paths supplied by clients are never trusted. Upload alone does not submit a prompt; send a message action to deliver the receipt to the selected session.
