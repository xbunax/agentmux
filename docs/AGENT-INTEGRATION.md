# Agent integration and mobile interaction

Verified against the installed CLI interfaces on 2026-10-15: Codex 0.162.1, Claude Code 2.1.287, and Pi 1.2.0. These interfaces evolve; fixture results and real-provider results are recorded separately in `VERIFICATION.md`.

## The interaction model

The iOS app presents conversations, tool cards, model selection, stop controls, and approval/question forms. It does not render terminal snapshots. AgentMux normalizes provider events and routes actions back to the originating process. Unsupported controls are hidden or explicitly marked; it never treats an approval dialog as an ordinary message.

| Source | Conversation and tools | Send / stop | Models | Approvals and questions |
| --- | --- | --- | --- | --- |
| New Codex session | App-server events | Native turn controls | Next turn | Command/file approvals, per-turn permissions, question forms |
| New Claude Code session | Bidirectional stream-json | Native input / interrupt | Native control | Tool permission responses and `AskUserQuestion` forms |
| New Pi session | JSONL RPC events | Native prompt / abort | Native control | Supported extension confirm/select/input/editor requests |
| Existing Pi with extension | Current SDK branch and streaming message | Same-process SDK | Same-process SDK | Existing interactive dialogs stay on Mac |
| Existing Codex / Claude / Pi TUI | Provider JSONL records | Guarded paste / Escape | On Mac | On Mac |

## Discovery and binding

`tmux list-panes -a` searches every session on the selected tmux server. AgentMux walks each pane's process tree, recognizes provider executables, interpreter entry points and configured launchers, and groups panes by window in iOS. A window title alone never identifies an Agent. Windows without an Agent are hidden. Split windows can contain several independently selectable Agents.

This covers the default server, or the server selected by an `AGENTMUX_TMUX` wrapper. It does not enumerate unrelated custom tmux sockets. Discovered Agents can be outside configured file roots; file transfer and new-session creation remain confined to those roots. Access grants control as the authenticated Mac user.

Claude's runtime PID/session metadata can bind a conversation automatically. Otherwise the app offers project-scoped conversation records for explicit selection, even when only one candidate exists. Selection changes the displayed history; it does not resume or replace the Agent. Modification time is never evidence of process ownership. Custom transcript directories and unusual launcher wrappers may need additional adaptation.

The TUI relay verifies the live Agent PID on every action, requires a recognizable empty editor, uses bracketed paste, rejects terminal control characters, and deduplicates request IDs. It rejects drafts and unrecognized screens. Escape requests cancellation without sending Ctrl-C to the shell. Concurrent Mac typing can still race a readiness check: avoid editing from both devices simultaneously. A successful paste acknowledges delivery to the editor, not model execution. Unknown outcomes must be inspected before retrying. Retained history and deduplication are bounded and are not durable across daemon restarts.

## Why existing terminal sessions differ

Codex App Server exposes threads, turns, items, models, approvals, and user-input requests. `thread/read` reads history; a new independent app-server process is not proof of ownership of an already-live TUI thread. The current Codex CLI additionally offers a shared-daemon proxy and queue interface. Native attachment through that shared daemon is a future improvement and is not implemented here. [Official App Server reference](https://developers.openai.com/codex/app-server/).

Claude's SDK routes tool approvals and clarifying questions through different response payloads; `AskUserQuestion` answers must be returned with the original questions. Its Remote Control feature keeps the existing process alive through Anthropic's service. AgentMux does not use that service or undocumented peer sockets as a generic local attachment protocol. [SDK user interaction](https://code.claude.com/docs/en/agent-sdk/user-input), [Remote Control](https://code.claude.com/docs/en/remote-control).

Pi distinguishes RPC mode from interactive mode. Its public extension API allows a bridge into the existing session, including user messages, current branch, model changes, and abort. This is why the optional Pi extension can provide stronger existing-process integration than terminal input forwarding. [Pi RPC documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md), [Pi extension documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md).

## Enable the Pi extension

For a new Pi process, use the absolute path to this checkout:

```sh
pi -e /absolute/path/to/agentmux/integrations/pi/agentmux.ts
```

To load it into an existing Pi process without restarting, place a link in Pi's extension directory, then run `/reload` in Pi:

```sh
mkdir -p ~/.pi/agent/extensions
ln -s /absolute/path/to/agentmux/integrations/pi/agentmux.ts ~/.pi/agent/extensions/agentmux.ts
```

`ln -s` will fail if that destination already exists; inspect it before replacing anything. With a custom `PI_CODING_AGENT_DIR`, use its `extensions` directory instead. No global extension is installed automatically by AgentMux.

The extension listens only on loopback with a random port and token. A private `0600` manifest in `~/Library/Application Support/AgentMux/bridges` binds it to its PID and working directory. `AGENTMUX_BRIDGE_DIR` overrides this directory and must match in both processes. AgentMux prefers this bridge whenever it exists; it does not silently downgrade a broken bridge to simulated input. Models come from Pi's available catalogue. Other extensions' interactive dialogs remain on the Mac.

## Remaining validation

The release app compiles, parser and forwarding fixtures pass, and the installed Pi SDK loads the real extension without a model request. Real iPhone interaction, live model streaming, real tool approvals, and cancellation during provider work still require end-to-end testing. Native managed sessions remain daemon-owned children, not existing tmux processes, and are not automatically restored after a daemon restart.
