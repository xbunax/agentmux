# AgentMux

Rust macOS service + SwiftUI iOS client. Version 0.2 development build.

## Features

- QR pairing: scan the Mac-generated code (camera or photo), confirm the Mac and host-key fingerprint, and connect without typing credentials.
- Built-in SSH on port 9848. The iOS client pins the Ed25519 host key from the QR and forwards HTTP directly inside encrypted SSH channels. No remote shell, arbitrary TCP forwarding or macOS SSH setup is required.
- Five-minute single-use enrollment tickets; random per-device credentials stored in iOS Keychain, hashed on the Mac; device revocation.
- Native structured sessions: Pi JSONL RPC, Codex app-server JSON-RPC, Claude Code bidirectional stream-json control protocol. Structured message display, tool results, supported approvals, cancellation, advertised model selection and slash-command panel.
- Existing tmux panes remain terminal-only: capture output, send literal text/commands and interrupt. No false claim of structured adoption.
- Create either a native structured session or a tmux terminal session in an existing approved directory.
- iOS settings for default directory and authorized roots, revision conflicts and atomic configuration updates.
- File listing and upload/download up to 8 MiB, without overwrite; capability-confined file access.
- Unsigned arm64 device IPA build script.

## Quick start: Mac → QR → iPhone

Requirements: Rust, tmux, installed/logged-in Codex / Claude Code / Pi. iOS 17+; Xcode and XcodeGen for builds.

```sh
cp agentmux.example.json agentmux.json
# Set existing project roots and actual executable paths (command -v codex/claude/pi).
# Prefer a dedicated project root, never the whole home directory.
cargo build --release
./target/release/agentmuxd
```

In a second terminal, from the same directory:

```sh
./target/release/agentmuxd pair
# If auto-detected LAN address is unsuitable:
./target/release/agentmuxd pair your-mac.tailnet-name.ts.net
```

Open `.agentmux/pair.svg` on the Mac or scan the terminal QR. In the App tap **扫码配对 Mac**, verify the displayed Mac/fingerprint, then confirm. No username, token, SSH key or URL entry is needed. Camera-denied users can select a QR image from Photos. Codes expire after 5 minutes; generating a new code invalidates outstanding tickets.

Mac and phone must have network reachability (same LAN or Tailscale). QR pairing does not bypass NAT or automatically create a VPN. Allow the AgentMux executable through the macOS firewall if prompted. It binds SSH to `0.0.0.0:9848`; the HTTP API remains **loopback-only** at `127.0.0.1:9847`. `AGENTMUX_SSH_BIND` can restrict SSH to a specific local address. Do not publish the pairing image or expose the service to the public internet without further operational hardening.

The daemon generates `.agentmux/admin.token` and `.agentmux/ssh_host_ed25519` with private permissions. `AGENTMUX_STATE` selects another private state directory; `AGENTMUX_CONFIG` selects another configuration file. Optional `AGENTMUX_TOKEN` overrides the local administrator token; both daemon and pairing CLI must use the same override. `AGENTMUX_TMUX` selects tmux. Initial agent login is performed on the Mac, not in the phone App.

## Structured sessions and capabilities

- Pi: `get_available_models` / `set_model`, extension/template/skill commands, native new-session/compact controls and extension UI dialogs.
- Codex: `model/list`; model selection is sent with the **next** `turn/start`, not a hot-switch of an active turn. Compact is a native control. Terminal-only slash commands are not listed as supported.
- Claude: initialization-advertised models and commands; `set_model`, streaming input/output and tool permission responses. CLI protocol compatibility depends on installed version.
- Unsupported approval shapes are shown as unsupported; interrupt instead of silently approving them.

Structured sessions run as daemon-owned child processes, **not tmux panes**. Existing tmux sessions are never silently restarted or converted. A daemon restart ends managed child processes; native provider session files may persist, but automatic resume is not implemented.

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
python3 scripts/smoke-test.py
python3.13 -m venv build/test-venv
build/test-venv/bin/pip install paramiko==3.5.1
build/test-venv/bin/python scripts/test-ssh-agents.py
# Uses real installed agents and sends a short provider request (may incur cost):
build/test-venv/bin/python scripts/test-ssh-agents.py --live
```

Stop development instances before integration tests (ports 9847/9848). Tests use temporary roots and credentials; tmux smoke tests use an isolated socket and `/dev/null` tmux config. Fake protocol fixtures are not proof of provider compatibility.

The Swift probe compiles **the exact SSHTransport.swift used by iOS** for Mac-side interoperability tests:

```sh
swift build --scratch-path build/swift-probe --product SSHProbe
# Generate a fresh QR first; this consumes it and revokes its test device afterward.
AGENTMUX_PAIR_JSON="$PWD/.agentmux/pair.json" build/swift-probe/debug/SSHProbe
```

See `docs/VERIFICATION.md` for actual verification evidence and device limitations, when available. A successful device build or desktop SSH test is not an iPhone end-to-end test.

## Limitations

- Structured snapshots are polled, not WebSocket replay; retained in daemon memory. No SQLite history or automatic managed-process resume yet.
- Message IDs prevent resubmission within a running managed session. A timed-out action may have executed; inspect state before retrying. No persistent cross-restart deduplication.
- Existing tmux discovery lists all approved panes; process-tree Agent identification is not yet implemented.
- The tmux view is a text snapshot, not an ANSI terminal emulator.
- No launchd installer, automatic updates, APNs, Android or multi-user roles.
- Mobile background suspension closes/invalidates transports; reconnect occurs on the next foreground request. Agents continue while the daemon remains running.

## Security

Single trusted-user service. Pairing grants terminal/Agent control as the Mac user. Directory filters are **not an Agent sandbox**: tools and terminal processes may access other files. Avoid sensitive files in approved roots. Secrets are not content-classified on download. Use trusted QR codes only; credentials in a QR ticket are sensitive until expiration. SSH private host keys never leave the Mac.

Remote clients cannot change agent executable paths or exceed roots loaded at startup. Narrowed roots persist and become the new ceiling after restart. Device removal immediately denies HTTP actions and new SSH authentications; it does not forcibly terminate an already-open SSH transport, which remains limited to the now-auth-denied API.

## API

Authenticated APIs use `Authorization: Bearer <device credential or local administrator token>`.

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/pair/issue` | Local-admin-only QR ticket creation |
| POST | `/v1/pair/complete` | Exchange SSH-authenticated single-use ticket |
| GET / DELETE | `/v1/devices` / `/v1/devices/{id}` | Devices / revoke |
| GET / PUT | `/v1/settings` | Configuration |
| GET / POST | `/v1/managed` | Structured session list / create |
| GET | `/v1/managed/{id}` | Structured snapshot |
| POST | `/v1/managed/{id}/actions` | Message, model, command, abort, approval |
| GET / POST | `/v1/sessions` | tmux list / create |
| GET | `/v1/sessions/{id}/output` | Terminal snapshot |
| POST | `/v1/sessions/{id}/input` / `interrupt` | Terminal control |
| GET | `/v1/files?path=...` | Directory list |
| GET / PUT | `/v1/file?path=...` | File transfer |
