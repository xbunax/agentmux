import { createServer } from 'node:http';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { mkdirSync, writeFileSync, renameSync, unlinkSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

export const bridgeDirectory = () => process.env.AGENTMUX_BRIDGE_DIR ?? join(homedir(), 'Library/Application Support/AgentMux/bridges');
export const digest = value => createHash('sha256').update(value).digest('hex');
export function agentPID(provider) {
    let pid = process.ppid;
    for (let count = 0; count < 8 && pid > 1; count++) {
        try {
            const line = execFileSync('/bin/ps', ['-p', String(pid), '-o', 'ppid=,comm='], { encoding: 'utf8', timeout: 1000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
            const match = line.match(/^(\d+)\s+(.+)$/);
            if (!match) break;
            if (match[2].split('/').at(-1) === provider) return pid;
            pid = Number(match[1]);
        } catch { break; }
    }
    return process.ppid;
}
export function manifests() {
    try {
        return readdirSync(bridgeDirectory()).filter(name => name.endsWith('.json')).slice(0, 512).flatMap(name => {
            try {
                const path = join(bridgeDirectory(), name), stat = statSync(path);
                if ((stat.mode & 0o077) || stat.size > 65536) return [];
                const value = JSON.parse(readFileSync(path, 'utf8'));
                return value.version === 2 ? [value] : [];
            } catch { return []; }
        });
    } catch { return []; }
}
export async function localRequest(manifest, path, value, timeout = 5000) {
    if (!Number.isInteger(manifest.port) || manifest.port < 1 || manifest.port > 65535 || !/^[a-f0-9]{64}$/.test(manifest.token)) throw new Error('Invalid private bridge');
    const response = await fetch(`http://127.0.0.1:${manifest.port}${path}`, {
        method: value === undefined ? 'GET' : 'POST', redirect: 'error', signal: AbortSignal.timeout(timeout),
        headers: { Authorization: `Bearer ${manifest.token}`, 'Content-Type': 'application/json' },
        body: value === undefined ? undefined : JSON.stringify(value),
    });
    if (!response.ok) throw new Error(`Bridge request failed (${response.status})`);
    return response.json();
}
export async function stdinJSON() {
    let text = '';
    for await (const chunk of process.stdin) { text += chunk; if (Buffer.byteLength(text) > 1024 * 1024) throw new Error('Hook input too large'); }
    return JSON.parse(text);
}
export async function startBridge({ provider, id = randomUUID(), cwd, nativePID, snapshot, action, event, close }) {
    const token = randomBytes(32).toString('hex');
    const path = join(bridgeDirectory(), `${provider}-${digest(id)}.json`);
    const delivered = new Map();
    let mutating = false;
    let closed = false;
    const server = createServer(async (request, response) => {
        const reply = (code, value) => {
            if (response.destroyed) return;
            response.writeHead(code, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(value));
        };
        if (request.headers.authorization !== `Bearer ${token}`) { reply(401, { error: 'Authentication required' }); return; }
        try {
            if (request.method === 'GET' && request.url === '/health') {
                reply(200, { bridge_id: id, bridge_pid: process.pid }); return;
            }
            if (request.method === 'GET' && request.url === '/snapshot') {
                reply(200, { messages: [], models: [], commands: [], model: '', busy: false, alive: true, approvals: [], error: null, revision: 0,
                    ...await snapshot(), bridge_id: id, bridge_pid: process.pid, source: `${provider}-plugin` });
                return;
            }
            if (request.method !== 'POST' || !['/actions', '/events'].includes(request.url)) { reply(404, { error: 'Unknown endpoint' }); return; }
            let size = 0; const chunks = [];
            for await (const chunk of request) {
                size += chunk.length;
                if (size > 128 * 1024) { reply(413, { error: 'Request too large' }); return; }
                chunks.push(chunk);
            }
            const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
            if (request.url === '/events') {
                if (!event) { reply(404, { error: 'Hooks unavailable' }); return; }
                reply(200, await event(value)); return;
            }
            if (value.agent_pid !== process.pid) { reply(409, { error: 'Plugin process changed; reopen the session' }); return; }
            const serial = !['abort', 'approval'].includes(value.action);
            if (serial && mutating) { reply(409, { error: 'Another action is in progress' }); return; }
            const needsID = ['message', 'command'].includes(value.action);
            if (needsID && (typeof value.request_id !== 'string' || !value.request_id || value.request_id.length > 128)) { reply(400, { error: 'request_id required' }); return; }
            if (value.action === 'message' && (typeof value.text !== 'string' || !value.text.trim() || Buffer.byteLength(value.text) > 65536)) { reply(400, { error: 'Valid message required' }); return; }
            const fingerprint = digest(JSON.stringify([value.action, value.text, value.model, value.provider]));
            if (needsID && delivered.has(value.request_id)) {
                const previous = delivered.get(value.request_id);
                reply(previous.fingerprint === fingerprint && previous.accepted ? 200 : 409, previous.accepted && previous.fingerprint === fingerprint ? { accepted: true } : { error: 'Previous delivery is uncertain or different. Inspect the conversation before retrying.' }); return;
            }
            if (needsID && delivered.size >= 1024) { reply(409, { error: 'Session request limit reached' }); return; }
            if (serial) mutating = true;
            try {
                if (needsID) delivered.set(value.request_id, { fingerprint, accepted: false });
                const result = await action(value);
                if (needsID) delivered.set(value.request_id, { fingerprint, accepted: true });
                reply(200, result ?? { accepted: true });
            } finally { if (serial) mutating = false; }
        } catch (error) { reply(Number.isInteger(error.status) ? error.status : 502, { error: error.publicMessage ?? 'Plugin operation failed. Inspect the Agent before retrying.' }); }
    });
    server.requestTimeout = 15000; server.headersTimeout = 5000;
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    const manifest = { version: 2, provider, id, pid: process.pid, agent_pid: nativePID, cwd, port: server.address().port, token, tmux_pane: process.env.TMUX_PANE ?? null };
    mkdirSync(bridgeDirectory(), { recursive: true, mode: 0o700 });
    const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
    writeFileSync(temporary, JSON.stringify(manifest), { mode: 0o600, flag: 'wx' }); renameSync(temporary, path);
    const shutdown = async () => {
        if (closed) return; closed = true;
        try {
            const current = JSON.parse(readFileSync(path, 'utf8'));
            if (current.pid === process.pid && current.token === token) unlinkSync(path);
        } catch { /* already removed or replaced */ }
        server.closeAllConnections(); server.close(); await close?.();
    };
    return { manifest, shutdown };
}
export function invalid(message, status = 409) { const error = new Error(message); error.status = status; error.publicMessage = message; return error; }
