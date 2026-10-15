import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { mkdirSync, writeFileSync, readFileSync, statSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { stdinJSON, manifests, localRequest, agentPID, bridgeDirectory, digest } from './shared/bridge.mjs';

const sleep = () => new Promise(resolve => setTimeout(resolve, 40));
async function liveManifest(event, nativePID) {
    const manifest = manifests().find(m => m.provider === 'codex' && m.id === event.session_id && m.cwd === event.cwd && m.agent_pid === nativePID);
    if (!manifest) return null;
    try {
        const health = await localRequest(manifest, '/health', undefined, 500);
        return health.bridge_id === manifest.id && health.bridge_pid === manifest.pid ? manifest : null;
    } catch { return null; }
}
async function bootstrap(event, nativePID) {
    mkdirSync(bridgeDirectory(), { recursive: true, mode: 0o700 });
    const lock = join(bridgeDirectory(), `codex-${digest(event.session_id)}.lock`);
    for (let attempt = 0; attempt < 50; attempt++) {
        const existing = await liveManifest(event, nativePID);
        if (existing) return existing;
        try { mkdirSync(lock, { mode: 0o700 }); }
        catch (error) {
            if (error.code !== 'EEXIST') throw error;
            try {
                const owner = Number(readFileSync(join(lock, 'owner'), 'utf8'));
                if (Number.isSafeInteger(owner) && owner > 1) {
                    try { process.kill(owner, 0); }
                    catch (failure) { if (failure.code === 'ESRCH') rmSync(lock, { recursive: true, force: true }); }
                }
            } catch {
                // A newly created lock may not have its owner file yet.
                try { if (Date.now() - statSync(lock).mtimeMs > 10000) rmSync(lock, { recursive: true, force: true }); } catch {}
            }
            await sleep(); continue;
        }
        try {
            writeFileSync(join(lock, 'owner'), String(process.pid), { mode: 0o600, flag: 'wx' });
            const existing = await liveManifest(event, nativePID);
            if (existing) return existing;
            const child = spawn(process.execPath, [fileURLToPath(new URL('./server.mjs', import.meta.url))], { detached: true, stdio: ['pipe', 'ignore', 'ignore'] });
            child.on('error', () => {});
            child.stdin.on('error', () => {});
            child.stdin.end(JSON.stringify({ session_id: event.session_id, cwd: event.cwd, transcript_path: event.transcript_path, model: event.model, agent_pid: nativePID }));
            child.unref();
            for (let poll = 0; poll < 50; poll++) {
                const manifest = await liveManifest(event, nativePID);
                if (manifest) return manifest;
                await sleep();
            }
            return null;
        } finally { rmSync(lock, { recursive: true, force: true }); }
    }
    return null;
}

try {
    const event = await stdinJSON();
    if (typeof event.session_id !== 'string' || typeof event.cwd !== 'string') process.exit(0);
    if (event.agent_id || event.parent_session_id) process.exit(0); // independent subagents are not the phone's target
    const nativePID = agentPID('codex');
    let manifest = await liveManifest(event, nativePID);
    if (!manifest && event.hook_event_name !== 'SessionEnd') {
        manifest = await bootstrap(event, nativePID);
    }
    if (manifest) {
        const result = await localRequest(manifest, '/events', { ...event, event_id: randomUUID() }, event.hook_event_name === 'PermissionRequest' ? 245000 : 2000);
        process.stdout.write(JSON.stringify(result));
    }
} catch { process.stderr.write('AgentMux plugin unavailable; continuing normal Codex interaction.\n'); }
