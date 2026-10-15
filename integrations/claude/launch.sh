#!/bin/sh
# Install agentmux-claude@agentmux first. Pass --resume SESSION_ID for an existing conversation.
export AGENTMUX_CLAUDE_CHANNEL=1
exec claude --dangerously-load-development-channels plugin:agentmux-claude@agentmux "$@"
