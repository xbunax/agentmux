import { stdinJSON, manifests, localRequest, agentPID } from './shared/bridge.mjs';
try {
    const event = await stdinJSON();
    if (typeof event.session_id !== 'string' || typeof event.cwd !== 'string' || event.agent_id) process.exit(0);
    const pid = agentPID('claude');
    const manifest = manifests().find(m => m.provider === 'claude' && m.agent_pid === pid && m.cwd === event.cwd);
    if (manifest) {
        const interactive = event.hook_event_name === 'PermissionRequest' || (event.hook_event_name === 'PreToolUse' && event.tool_name === 'AskUserQuestion');
        const result = await localRequest(manifest, '/events', event, interactive ? 245000 : 1500);
        if (interactive) process.stdout.write(JSON.stringify(result));
    }
} catch { process.stderr.write('AgentMux hook unavailable; continuing local Claude session.\n'); }
