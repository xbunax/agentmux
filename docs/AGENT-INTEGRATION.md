# Agent integration and mobile interaction

Interface baseline: Codex 0.162.1, Claude Code 2.1.287 and Pi 1.2.0, inspected on 2026-10-15. [Verification](VERIFICATION.md) separates fixtures, real CLI checks and unverified device behavior.

## Existing sessions are first-class

Manually running `tmux new-session … codex`, `claude` or `pi` is supported. Start AgentMux later and open that Agent from iOS. No AgentMux-created replacement is required. The app presents chat, command suggestions and selection cards, rather than a terminal screen.

| Connection | Messages / stop | Commands and models | Approvals / questions |
| --- | --- | --- | --- |
| Manually started tmux Agent, no plugin | Guarded editor paste / Escape | Supported built-in suggestions; recognized menus operate the original window | Recognized selection menus; arbitrary text forms stay on Mac |
| Existing Codex with plugin | Shared-daemon queue / native interrupt | Native model override, compact, status; additional tmux commands when linked | Trusted PermissionRequest hook; other forms need TUI support or Mac |
| Existing Claude with Channel plugin | Channel notifications; Escape when linked to tmux | Native status; additional tmux commands when linked | Channel allow/deny; AskUserQuestion forms remain unsupported |
| Existing Pi with extension | Same-process SDK / abort | Available models, compact, session, public extension commands | Other extensions' dialogs remain on Mac, unless recognized as a linked tmux menu |
| AgentMux-created Codex / Claude / Pi | Provider-native child protocol | Native controls supported by that adapter | Structured supported approvals and question forms |

Activation requirements are in [PLUGINS.md](PLUGINS.md). Plugins are optional for ordinary tmux forwarding. Installing one does not activate it inside every existing process.

## Discovery and process identity

`tmux list-panes -a` covers all sessions on the selected server. AgentMux walks each pane's process tree, recognizes executables/interpreter entry points/configured launchers, and groups Agent panes by window. Ordinary windows are hidden. Window titles alone never identify an Agent.

The default server is used unless `AGENTMUX_TMUX` selects another server through a wrapper. Unrelated custom tmux sockets are not enumerated. Discovery includes Agents outside file roots; file transfers and new-session creation remain confined to configured roots.

Every TUI action checks the live Agent PID. A plugin is linked to a pane only when its advertised pane, native PID and provider match fresh process discovery. The phone receives neither the plugin's loopback token nor its private transcript path.

## Editor and menu forwarding

Sending requires a recognizable empty editor. Dim Codex/Claude placeholders and Pi's default software cursor are supported; real Mac drafts are rejected. Text uses bracketed paste, rejects terminal control characters and requires a deduplicated request ID. Escape requests cancellation without sending Ctrl-C to a shell.

Recognized numbered Codex/Claude lists and bordered Pi arrow lists become choice cards. Selection sends arrows only. Confirmation requires a separate tap and a fresh hash covering the provider, PID, context, options and current selection. A changed menu rejects stale confirmation. Unrecognized dialogs refuse input instead of guessing.

Concurrent Mac input can still race a check. Avoid editing simultaneously. Delivery acknowledgment does not prove model execution. Inspect uncertain outcomes before retrying. Deduplication is bounded and does not survive service/plugin restarts.

## History does not control attachment

History is optional for sending. Claude runtime metadata or plugin hooks can identify the exact log. Otherwise the app offers project-scoped records for explicit display selection, even with a single candidate. Modification time is never evidence of process ownership. Selecting a record changes displayed history only; it never resumes or replaces an Agent. Unusual transcript layouts may need adaptation.

## Native protocol sources

Codex uses the existing shared daemon through `app-server proxy` and `queue --thread`, with a session ID registered by trusted hooks. It never starts or resumes an independent copy of that live thread. These interfaces must be available in the installed CLI. [Official App Server reference](https://developers.openai.com/codex/app-server/), [hooks](https://developers.openai.com/codex/hooks), [slash commands](https://developers.openai.com/codex/cli/slash-commands/).

Claude uses documented MCP Channel notifications and its permission channel. Custom Channels are a research preview with explicit startup opt-in and applicable organization policy. Channel delivery does not acknowledge the final approval outcome if the Mac answered first. [Channels reference](https://code.claude.com/docs/en/channels-reference).

Pi uses its public extension API inside the existing process. RPC remains the separate protocol for AgentMux-created Pi children. Extension dialogs are not monkeypatched into remote forms. [Pi extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md), [RPC](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md).

## Validation boundary

The real Pi TUI passed an offline model-menu change after starting manually before AgentMux. Existing real Codex panes passed read-only readiness checks. Three-provider TUI fixtures and native plugin protocol/API fixtures passed; they do not prove live model/tool behavior. Real iPhone operation and full live-provider approval, streaming and cancellation still require end-to-end validation. No existing user Agent was restarted for these checks.
