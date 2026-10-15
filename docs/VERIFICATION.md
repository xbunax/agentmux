# Verification record

## Agent conversation UI — 2026-10-15, version 0.3

The iOS camera/photo scanner and terminal screen have been removed. SSH is the connection flow. The app groups discovered Agent panes by tmux window and presents conversations, tool cards, native models, cancellation, approvals, and question forms according to source capabilities.

| Check | Result |
| --- | --- |
| Rust unit tests | 21 passed: configuration/authentication/confinement, process-tree identification, provider transcript parsing, Pi branch selection, incomplete JSONL, editor readiness, control-character rejection, Codex permission/question response schemas, and tool result merging |
| Formatting and Clippy | Passed, warnings denied |
| Isolated real tmux test | Passed across multiple sessions, renamed windows, split panes, ordinary-window filtering, discovery outside file roots, explicit history selection, PID binding, bracketed message delivery, deduplication, Mac draft rejection, and exited-process rejection |
| Pi extension fixture | Actual TypeScript extension passed authenticated HTTP, private manifest permissions, branch/streaming snapshots, draft/dialog rejection, deduplication, abort, models, and PID validation |
| Pi bridge through daemon | Actual extension in a fake SDK host passed tmux process discovery, chat snapshots, message delivery, abort, and model selection through the Rust API |
| Installed Pi SDK | Pi 1.2.0 loaded the real extension in RPC mode; its private bridge returned the same live PID/cwd and a valid session snapshot. No model prompt was sent |
| HTTP/files regression | Passed auth, config persistence/conflicts, legacy tmux controls, file transfer, size limits, confinement, symlinks, and no-overwrite behavior |
| Three native protocol fixtures | Pi, Codex, and Claude initialization, model selection, replies, commands and deduplication passed over real SSH/HTTP with fake providers |
| Normal SSH / actual iOS transport | Password and passphrase-protected Ed25519 passed discovery/enrollment, dynamic API port forwarding, reconnect, revocation, changed-host-key rejection, incorrect-login rejection, and missing-service rejection |
| Legacy restricted SSH | Ticket exchange/reconnect, forwarding restrictions, shell rejection, authentication and revocation passed |
| iOS Release build | Unsigned arm64 IPA compiled and packaged with the chat interface, approvals and question forms |

Relevant commands:

```sh
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
python3 scripts/test-tmux-agents.py
node scripts/test-pi-extension.mjs
python3 scripts/test-pi-load.py
python3 scripts/smoke-test.py
build/test-venv/bin/python scripts/test-ssh-agents.py
build/test-venv/bin/python scripts/test-ssh-login.py
sh scripts/build-unsigned-ipa.sh
```

The tmux test and smoke test use temporary tmux sockets. Service tests now select independent local ports, leaving an already-running AgentMux instance untouched. SSH tests require Paramiko 3.5.1; the normal-login test uses the compiled `SSHProbe` built from the actual iOS transport source. The TypeScript fixture requires Node.js 22.18+.

## What remains unverified

- Real iPhone interaction: SSH login against macOS Remote Login, conversation selection, text entry, scrolling, Dynamic Type, approvals, question forms, and foreground/background reconnection.
- Live model/tool work for all three providers, including streaming, approvals, cancellation, and model changes. Fixture success is not proof of live-provider compatibility. No model requests were made during this update.
- Pi extension operation in a real interactive tmux session during a tool-using task. Its real SDK load was verified in RPC mode; the same-process end-to-end relay used a fixture host.
- Existing Codex/Claude TUI editor recognition across installed versions, themes and custom launchers. Unexpected screens refuse input. These sources do not have full native attachment, model switching or approval forwarding.
- RSA login compatibility with the intended SSH server remains dependent on accepted signature algorithms.

Existing processes are never restarted or converted automatically. No running user service was stopped for testing. Updating a daemon that owns native sessions should wait until their work is complete. Read [Agent integration](AGENT-INTEGRATION.md) for the capability matrix, protocol sources, and Pi installation instructions.
