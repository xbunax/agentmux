import { stdinJSON, manifests, localRequest, agentPID } from './shared/bridge.mjs';
try {
    const event = await stdinJSON();
    if (typeof event.session_id !== 'string' || typeof event.cwd !== 'string' || event.agent_id) process.exit(0);
    const pid = agentPID('claude');
    const manifest = manifests().find(m => m.provider === 'claude' && m.agent_pid === pid && m.cwd === event.cwd);
    if (manifest) await localRequest(manifest, '/events', event, 1500);
} catch { process.stderr.write('AgentMux hook unavailable; continuing local Claude session.\n'); }
