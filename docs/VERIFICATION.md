# Verification record

## Disabled send buttons in real manual sessions — 2026-10-15

Reproduced against the user's original `test` session using GET requests only: Codex was ready, while Claude Code and Pi were incorrectly blocked. Claude had a hidden hardware cursor in its bordered, empty `❯` editor. Pi's Vim extension appended `INSERT` to the lower editor border.

The readiness parser now accepts those layouts without accepting existing drafts, recognized selection menus or Vim NORMAL/VISUAL screens. No iOS change is needed: the send button follows the daemon's message capability.

- All five original Agent panes, including the real Claude and Pi panes, reported input-ready after the fix using an isolated daemon. No text was sent to those user processes.
- 29 Rust unit tests and Clippy passed. Added actual-layout regressions for hidden Claude cursors/nonbreaking spaces and Pi's styled Vim INSERT border, including rejection cases.
- The three-provider manual tmux fixture now reproduces those layouts; message delivery/deduplication, Mac draft rejection, menu selection/confirmation, explicit approval and cancellation passed with original process PIDs preserved.
- The installed Pi's default TUI still passed the isolated offline `/model` navigation/confirmation test. This does not establish real Claude/Pi model-response correctness or iPhone end-to-end correctness.

Rebuild/restart only the Mac daemon to load this fix. Existing tmux Agent processes do not need restarting, and the current iOS app does not need reinstalling.

## Existing manual sessions and plugins — 2026-10-15, version 0.4

History binding and dim-placeholder false negatives previously prevented some manually started Agents from receiving input. History is now optional for control. iOS adds inline slash suggestions, explicit selection/confirmation cards and provider plugin sessions.

| Check | Result |
| --- | --- |
| Rust unit tests | 27 passed, including placeholder/RGB/draft protection, Pi software cursor and unnumbered lists, stale menu identity and private plugin metadata |
| Three-provider manual tmux acceptance | Real isolated tmux, fake interactive providers started **before** the daemon. Passed send/dedup, no-history input, slash/model menu, navigation without execution, stale confirmation rejection, explicit file-write approval, cancellation and unchanged wrapper/Agent child PIDs. No managed session created |
| Real existing Codex, read-only | Both original user panes discovered and reported input-ready with four slash suggestions. GET requests only; no messages or controls sent |
| Real installed Pi TUI | Pi 1.2.0 started manually before AgentMux with isolated config, offline mode, no extension and dummy local models. Passed default software-cursor recognition, `/model`, unnumbered menu, navigation/confirmation and actual model change; original PID preserved. No model prompt sent |
| Claude/Codex plugin protocols | Official MCP SDK fixture passed Claude messages/replies and permission notifications. Codex proxy fixture passed exact-thread queue/model/compact/interrupt and explicit PermissionRequest hook denial; no independent thread start/resume. Concurrent hooks created one bridge |
| Native plugins through Rust API | Externally launched Claude/Codex plugins discovered, iOS-shaped snapshots and status commands passed, stale PIDs rejected. Actual Pi extension in a fake SDK host passed generic plugin discovery/snapshot/model action and pane binding |
| Provider packaging | Bundled Codex marketplace installation succeeded with temporary CODEX_HOME; Claude CLI manifest validation passed with a naming warning. User global plugin settings unchanged |
| iOS Release | Version 0.4.0/build 4 unsigned arm64 IPA compiled with slash completion, plugin list, menu cards and linked-pane stop route |

Additional commands:

```sh
python3 scripts/test-manual-tmux.py
python3 scripts/check-existing-tmux.py  # read-only against existing panes
python3 scripts/test-real-pi-tui.py    # real offline Pi, isolated tmux
python3 scripts/package-plugins.py
npm ci --ignore-scripts --prefix dist/plugins/agentmux-claude
node scripts/test-plugin-protocols.mjs
```

These checks do not establish real iPhone end-to-end correctness or live model/tool execution across all providers. Existing Codex checks did not send input. Claude native Channels require explicit opt-in and applicable provider policy; installation alone cannot activate them in an already-running process. General free-text dialogs and arbitrary extension UIs are not automatically supported.

## Agent conversation UI — 2026-10-15, version 0.3

The iOS camera/photo scanner and terminal screen have been removed. SSH is the connection flow. The app groups discovered Agent panes by tmux window and presents conversations, tool cards, native models, cancellation, approvals, and question forms according to source capabilities.

| Check | Result |
| --- | --- |
| Rust unit tests | 22 passed: configuration/authentication/confinement, process-tree identification, provider transcript parsing, Pi branch selection, incomplete JSONL, editor readiness, control-character rejection, Codex permission/question response schemas, and tool result merging |
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
- Existing Codex/Claude TUI editor/menu recognition across other versions, themes and custom launchers. Unexpected screens refuse input. Version 0.4 adds standard menu forwarding and optional native plugins; full live-provider operation remains unverified.
- RSA login compatibility with the intended SSH server remains dependent on accepted signature algorithms.

Existing processes are never restarted or converted automatically. No running user service was stopped for testing. Updating a daemon that owns native sessions should wait until their work is complete. Read [Agent integration](AGENT-INTEGRATION.md) for the capability matrix, protocol sources, and Pi installation instructions.
