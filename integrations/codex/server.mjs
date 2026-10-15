import { spawn } from 'node:child_process';
import { resolve } from 'node:path';
import { startBridge, stdinJSON, invalid } from './shared/bridge.mjs';
import { CodexRPC } from './rpc.mjs';

const initial = await stdinJSON();
if (typeof initial.session_id !== 'string' || !initial.session_id || typeof initial.cwd !== 'string') process.exit(1);
const state = { ...initial, busy: false, model: initial.model ?? '', messages: [], revision: 0 };
const pending = new Map();
const rpc = new CodexRPC();
const commands = [
    { name: 'model', description: '选择下一条消息使用的模型', kind: 'model' },
    { name: 'compact', description: '压缩当前 Codex 会话上下文', kind: 'command' },
    { name: 'status', description: '查看插件连接及会话状态', kind: 'command' },
];
let modelOverride = '';
let bridge;
function clearApprovals() { for (const approval of pending.values()) approval.finish({}); pending.clear(); }
async function inspect() {
    await rpc.connect();
    const result = await rpc.call('thread/read', { threadId: state.session_id, includeTurns: false });
    const thread = result.thread;
    if (thread?.id !== state.session_id || resolve(thread.cwd) !== resolve(state.cwd)) throw invalid('Codex 会话身份与插件登记不一致。');
    const status = typeof thread.status === 'string' ? thread.status : thread.status?.type;
    if (status === 'notLoaded') throw invalid('此 Codex 会话已不在运行，请在 Codex 中恢复后再连接。');
    return { thread, busy: status === 'active' };
}
function queue(text, files = []) {
    return new Promise((resolvePromise, reject) => {
        const args = ['queue', '--thread', state.session_id, '--message', text];
        for (const file of files) if (file.mime_type?.startsWith('image/')) args.push('--image', file.path);
        if (process.env.AGENTMUX_CODEX_SOCKET) args.push('--remote', 'unix://' + process.env.AGENTMUX_CODEX_SOCKET);
        if (modelOverride) args.push('--model', modelOverride);
        const child = spawn(rpc.executable, args, { cwd: state.cwd, stdio: ['ignore', 'pipe', 'ignore'] });
        let size = 0;
        child.stdout.on('data', chunk => { size += chunk.length; if (size > 65536) child.kill(); });
        const timer = setTimeout(() => child.kill(), 12000);
        child.on('error', () => { clearTimeout(timer); reject(invalid('无法调用 Codex 的 queue 命令。', 502)); });
        child.on('exit', code => { clearTimeout(timer); code === 0 ? resolvePromise() : reject(invalid('Codex 未确认消息入队，请查看会话后再重试。', 502)); });
    });
}
async function models() {
    const data = []; let cursor;
    for (let page = 0; page < 20; page++) {
        const value = await rpc.call('model/list', { ...(cursor ? { cursor } : {}) });
        data.push(...(value.data ?? [])); cursor = value.nextCursor;
        if (!cursor) break;
    }
    return data.map(model => ({ id: model.model, name: model.displayName ?? model.model, provider: '' }));
}
bridge = await startBridge({
    provider: 'codex', id: state.session_id, cwd: state.cwd, nativePID: state.agent_pid,
    snapshot: async () => {
        let error = null, alive = true, available = [];
        try { const current = await inspect(); state.busy = current.busy; available = await models(); }
        catch (failure) { error = failure.publicMessage ?? 'Codex 共享服务暂不可用'; alive = false; }
        return { native_session_id: state.session_id, transcript_path: state.transcript_path,
            messages: state.messages, models: available, model: modelOverride || state.model, busy: state.busy,
            commands, approvals: [...pending.values()].map(a => a.view), alive, error, revision: state.revision,
            capabilities: { message: alive, abort: alive && state.busy, models: alive, approvals: true },
            notice: '已连接原来的 Codex 会话；工作时发送的消息会进入 Codex 队列。' };
    },
    action: async action => {
        if (action.action === 'approval') {
            const approval = pending.get(action.request_id);
            if (!approval) throw invalid('审批已结束或超时。');
            pending.delete(action.request_id);
            approval.finish({ hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: action.approved === true ? { behavior: 'allow' } : { behavior: 'deny', message: 'Denied from AgentMux' } } });
            return;
        }
        state.busy = (await inspect()).busy;
        if (action.action === 'message') {
            if (action.text.startsWith('/')) throw invalid('请从补全列表选择插件支持的命令；不会把终端命令作为聊天文本发送。', 400);
            await queue(action.text, action.uploaded_files);
        } else if (action.action === 'model') {
            if (!(await models()).some(m => m.id === action.model)) throw invalid('此模型不在 Codex 的可用列表中。', 400);
            modelOverride = action.model;
        } else if (action.action === 'abort') {
            const turns = await rpc.call('thread/turns/list', { threadId: state.session_id, limit: 1, sortDirection: 'desc', itemsView: 'notLoaded' });
            const turn = turns.data?.find(t => t.status === 'inProgress');
            const turnID = turn?.id ?? (state.busy ? state.turn_id : undefined);
            if (!turnID) throw invalid('当前没有可取消的任务。');
            await rpc.call('turn/interrupt', { threadId: state.session_id, turnId: turnID });
        } else if (action.action === 'command' && action.text === 'compact') {
            if (state.busy) throw invalid('请等待当前任务完成。');
            await rpc.call('thread/compact/start', { threadId: state.session_id });
        } else if (action.action === 'command' && action.text === 'status') {
            state.messages = [{ id: 'plugin-status', role: 'system', text: `Codex · ${state.session_id}\n${state.cwd}\n${state.busy ? '正在工作' : '就绪'}` }];
        } else throw invalid('此操作尚未由 Codex 插件公开。', 400);
    },
    event: async event => {
        if (event.session_id !== state.session_id || resolve(event.cwd) !== resolve(state.cwd)) throw invalid('Hook session mismatch', 400);
        state.revision++;
        if (typeof event.transcript_path === 'string') state.transcript_path = event.transcript_path;
        if (typeof event.model === 'string') state.model = event.model;
        if (typeof event.turn_id === 'string') state.turn_id = event.turn_id;
        if (['UserPromptSubmit', 'PreToolUse', 'PostToolUse'].includes(event.hook_event_name)) state.busy = true;
        if (['Stop', 'Interrupt', 'SessionEnd'].includes(event.hook_event_name)) { state.busy = false; clearApprovals(); }
        if (event.hook_event_name === 'SessionEnd') setTimeout(() => { bridge.shutdown().then(() => process.exit(0)); }, 50);
        if (event.hook_event_name !== 'PermissionRequest') return {};
        if (pending.size >= 16) throw invalid('Too many pending approvals');
        const id = event.event_id;
        if (typeof id !== 'string') throw invalid('Approval ID required', 400);
        return new Promise(resolvePromise => {
            const timer = setTimeout(() => { pending.delete(id); resolvePromise({}); }, 240000);
            pending.set(id, { view: { id, title: `允许 ${event.tool_name ?? '工具操作'}？`, detail: JSON.stringify(event.tool_input ?? {}, null, 2), options: [], kind: 'confirm', questions: [] },
                finish: result => { clearTimeout(timer); resolvePromise(result); } });
        });
    }, close: async () => { clearApprovals(); rpc.close(); },
});
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => bridge.shutdown().then(() => process.exit(0)));
// A crashed TUI cannot send SessionEnd. Do not leave its sidecar alive forever.
if (Number.isSafeInteger(state.agent_pid) && state.agent_pid > 1) {
    setInterval(() => {
        try { process.kill(state.agent_pid, 0); }
        catch (error) { if (error.code === 'ESRCH') bridge.shutdown().then(() => process.exit(0)); }
    }, 10000).unref();
}
