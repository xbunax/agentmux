import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { invalid } from './shared/bridge.mjs';

// Connect only to the already-running shared daemon. Never resume a live rollout in a new server.
export class CodexRPC {
    constructor(executable = process.env.AGENTMUX_CODEX_BIN ?? 'codex') { this.executable = executable; this.pending = new Map(); }
    async connect() {
        if (this.initialized) return this.initialized;
        this.initialized = this.open();
        try { await this.initialized; }
        catch (error) { this.close(); throw error; }
    }
    async open() {
        const args = ['app-server', 'proxy'];
        if (process.env.AGENTMUX_CODEX_SOCKET) args.push('--sock', process.env.AGENTMUX_CODEX_SOCKET);
        this.child = spawn(this.executable, args, { stdio: ['pipe', 'pipe', 'ignore'] });
        this.child.stdin.on('error', () => {});
        const ended = () => {
            this.initialized = undefined;
            for (const pending of this.pending.values()) pending.reject(invalid('Codex 共享服务不可用；此插件需要默认共享 daemon，或配置 AGENTMUX_CODEX_SOCKET。', 502));
            this.pending.clear();
        };
        this.child.on('error', ended); this.child.on('exit', ended);
        const lines = createInterface({ input: this.child.stdout });
        lines.on('line', line => {
            let value; try { value = JSON.parse(line); } catch { return; }
            const pending = this.pending.get(String(value.id));
            if (pending && !value.method) {
                this.pending.delete(String(value.id));
                if (value.error) pending.reject(invalid('Codex 拒绝了此操作，请检查当前会话状态。', 409));
                else pending.resolve(value.result);
            } else if (value.method && value.id !== undefined) {
                // This read/control client does not take ownership of unsolicited approval requests.
                this.write({ id: value.id, error: { code: -32601, message: 'Use the session PermissionRequest hook' } });
            }
        });
        await this.call('initialize', { clientInfo: { name: 'agentmux-plugin', title: 'AgentMux', version: '0.4.0' } });
        this.write({ method: 'initialized' });
    }
    write(value) { this.child?.stdin.write(JSON.stringify(value) + '\n'); }
    call(method, params) {
        const id = randomUUID();
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(id); reject(invalid('Codex 操作超时；请查看会话后再决定是否重试。', 504));
            }, 8000);
            this.pending.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
            this.write({ id, method, params });
        });
    }
    close() { this.child?.kill(); this.initialized = undefined; }
}
