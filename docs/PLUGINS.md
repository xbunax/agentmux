# Existing-session plugins

Ordinary manually started tmux Agents work through guarded forwarding without these plugins. Plugins add provider-native controls to the original session. Installation never requires creating the conversation through AgentMux.

## Build bundles

Requirements: Node.js 22.18+; the provider CLI installed and logged in on the Mac.

```sh
python3 scripts/package-plugins.py
npm ci --ignore-scripts --prefix dist/plugins/agentmux-claude
```

Each generated directory in `dist/plugins/` is self-contained. Claude needs the installed `node_modules` included when the provider copies its plugin directory. Packaging does not modify global provider settings.

## Codex

Register the local marketplace and install:

```sh
codex plugin marketplace add /absolute/path/to/agentmux/dist/plugins --json
codex plugin add agentmux-codex@agentmux --json
```

Review and trust the plugin's hooks through Codex's normal trust flow. Enable them in the intended session using the installed Codex plugin workflow. Until hooks run and register that session, its tmux forwarding remains available. A process that cannot reload plugins must continue through TUI forwarding, or load the plugin when that conversation is next resumed. AgentMux does not restart it automatically.

The plugin queues text to the hook's exact session ID via the shared Codex daemon. It supports model overrides for queued messages, compact, status, interrupt and explicit PermissionRequest allow/deny. It never calls `thread/start` or `thread/resume`. `--no-daemon` sessions cannot use this native bridge. `AGENTMUX_CODEX_BIN` overrides the executable; `AGENTMUX_CODEX_SOCKET` selects a nondefault shared Unix socket.

## Claude Code

Register/install the local marketplace in Claude Code:

```text
/plugin marketplace add /absolute/path/to/agentmux/dist/plugins
/plugin install agentmux-claude@agentmux
```

Native incoming messages require Claude's development Channel opt-in. After installation, use the bundle launcher, optionally resuming the same saved conversation:

```sh
sh /absolute/path/to/agentmux/dist/plugins/agentmux-claude/launch.sh
sh /absolute/path/to/agentmux/dist/plugins/agentmux-claude/launch.sh --resume SESSION_ID
```

The launcher sets `AGENTMUX_CLAUDE_CHANNEL=1` and passes `--dangerously-load-development-channels plugin:agentmux-claude@agentmux`. Review Claude's normal Channel trust prompt; organization policy may prevent Channels. Merely installing the MCP server does not enable incoming Channel messages. Inactive connections are omitted from the native plugin list; their tmux Agent remains accessible.

An already-running Claude process without Channel opt-in continues through TUI forwarding. The native Channel cannot be hot-enabled by AgentMux. It supports user messages, replies and tool allow/deny; other native controls are not advertised. When the plugin is verified against a tmux pane, supported slash commands, menus and Escape use that original pane. Full `AskUserQuestion` forms remain on the Mac. [Official Channel protocol and restrictions](https://code.claude.com/docs/en/channels-reference).

## Pi

Load the source extension when launching Pi manually:

```sh
pi -e /absolute/path/to/agentmux/integrations/pi/agentmux.ts
```

For an already-running Pi, link the extension and run `/reload` inside Pi:

```sh
mkdir -p ~/.pi/agent/extensions
ln -s /absolute/path/to/agentmux/integrations/pi/agentmux.ts ~/.pi/agent/extensions/agentmux.ts
```

Inspect an existing destination instead of overwriting it. With a custom `PI_CODING_AGENT_DIR`, use its `extensions` directory. The SDK bridge exposes the current branch/stream, messages, abort, available models, compact, session information and public extension commands. Dialogs owned by other extensions remain local unless the tmux menu recognizer supports their layout.

## Discovery and troubleshooting

Plugins listen on random loopback ports with private `0600` manifests under `~/Library/Application Support/AgentMux/bridges`. If overriding `AGENTMUX_BRIDGE_DIR`, set the same directory for AgentMux and provider processes. No extra port needs opening over the network.

The iOS list shows active connections under **插件连接 · 原有会话**. A verified matching tmux entry is deduplicated. A stopped/unavailable plugin must not be confused with a stopped Agent: the original tmux process remains separately discoverable. Refresh the list after activation.

Provider commands exposed by a native plugin and terminal-only slash commands use different routes. Suggestions cover advertised/supported commands, not every custom skill. Unsupported requests return an error rather than being sent as ordinary chat text. Finish daemon-owned tasks before restarting AgentMux; externally started tmux Agents are not its children.
