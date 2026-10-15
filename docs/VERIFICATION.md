# Verification record

## Structured interaction adapters and plugin research — 2026-10-15, version 0.6

Read-only inspection found the real `test` panes displaying Codex reasoning intensity, Claude's wrapped model menu, and Pi's search selector with clipped bottom help. The old adjacent-row/footer assumptions suppressed their cards. The new structural registry uses layout/style data rather than model names, question text or approval wording. A generic card exposes validated current actions, adjacent navigation, optional search and explicit confirmation.

- 34 Rust tests and Clippy passed, including original narrow-frame fixtures, arbitrary profile/choice names, wrapped descriptions, a single search result with dim annotations, and printed examples above a live editor that must not become controls.
- Isolated three-provider tmux acceptance passed; Codex now explicitly exercises model selection followed by a second intensity dialog, then a server-advertised session-only control. Stale menus and forged controls are rejected; original PIDs are preserved.
- GET-only checks against all five original user panes found the three `test` menus visible, without sending any input to those processes.
- Real Pi 1.2.0 passed a 47×23, 73-model offline selector/search/confirmation test. Its actual SDK also completed model change and arbitrary select/confirm/input cards through the Rust API, dismissing the original Mac dialog and resuming the original continuation. The documented symlink installation loads correctly.
- Packaged Claude question hook passed dynamic question rendering, exact input preservation, original hook answer return and incomplete/stale answer rejection. Native permission-hook denial passed without Channel opt-in; existing Channel permission notifications still passed through their separate route.
- Codex fixture passed dynamically advertised reasoning options, rejection of unsupported effort, and exact-thread `thread/settings/update`. The installed Codex 0.162.1 generated the matching experimental schema. No extra thread was started or resumed.
- iOS 0.6.0/build 6 Release compiled with generic action/search cards and provider-advertised model/intensity selection. No real iPhone UI test was performed.

See [research, sources, architecture and limits](INTERACTION-PLUGINS.md). Claude Mods configuration integration remains research; hooks do not export every built-in picker or network permission dialog. Live Codex settings and Claude hook behavior during actual provider tasks remain unverified. No model request was sent, no user's Agent was restarted, and the running user daemon was left untouched.

## Telegram-inspired UI and temporary chat attachments — 2026-10-15, version 0.5

The iOS app now has searchable/pinnable Agent rows, provider filters, adaptive navigation, themed settings/files, message bubbles, rich CLI command cards, copyable code blocks, searchable command/model sheets, and explicit menu confirmation. Chat uses a paperclip picker, removable attachment tray, and photo/file cards. Drafts and pending request IDs belong to each conversation.

Uploads are private, authenticated receipts under Mac `/tmp`, separate from file-browser roots. Sending delivers the caption and actual file paths to the selected original Agent; supported native routes also deliver images. Upload alone does not submit a prompt.

| Check | Result |
| --- | --- |
| Rust | 30 unit tests passed; formatting and Clippy with warnings denied passed |
| Temporary attachments | All three managed protocol fixtures received exact image input plus caption/file references. Passed private `/tmp` permissions, authenticated upload/download, Unicode names, MIME sniffing, idempotency, changed-payload conflicts, traversal/oversize/unknown-ID rejection and digest verification |
| Manual tmux Agents | Existing fixture processes for all three providers received attachment references with multiline captions in one bracketed-paste message; duplicate request delivered once. Existing draft, menu, approval and cancellation checks still passed; original Agent PIDs preserved |
| Claude/Codex plugins | Actual packaged bridge code through Rust API passed Codex original-thread `--image` queue and Claude MCP image-tool byte equality, deduplication and forged image-path rejection; existing approval, abort and stale-PID checks passed |
| Pi SDK | Actual extension under fixture host passed image content/base64 forwarding, alongside existing control checks |
| Rich presentation | Swift Foundation probe passed CLI tag formatting, ANSI cleanup, literal XML/code preservation, code-fence parsing and attachment receipt presentation |
| UI layout | Actual SwiftUI source compiled/rendered via offline Mac Catalyst fixture in dark/light appearance: conversation list, chat, slash suggestions, menu cards and attachment tray. No Keychain reads, network connections or model calls |
| iOS Release | Unsigned arm64 IPA version 0.5.0/build 5 compiled; packaged version and SHA-256 sidecar verified |
| File/API regression | Existing smoke test passed authentication, config conflicts, tmux controls, file transfer, boundaries, symlink/size checks and no-overwrite behavior |

Commands added: `python3 scripts/test-attachments.py`, `python3 scripts/preview-ios-ui.py --screen attachments`, and the Swift presentation probe documented in README. The upload tests use isolated daemon state and remove their temporary receipt directories.

Mac Catalyst images are layout previews, not iPhone screenshots; platform chrome, keyboard, Dynamic Type, document/Photos picker and real-device interaction still need iPhone verification. Native wire-format fixtures do not establish live model image interpretation. No prompt was sent to the user's running Agents. Update both Mac and iOS for chat uploads, and update/reload plugins for native image inputs. Temporary uploads are not durable storage.

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
