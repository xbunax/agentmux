import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { startBridge, agentPID, invalid } from './shared/bridge.mjs';

const nativePID = agentPID('claude');
const state = { native_session_id: '', cwd: process.cwd(), transcript_path: undefined, messages: [], busy: false, revision: 0 };
const approvals = new Map();
let connected = false;
const channelEnabled = process.env.AGENTMUX_CLAUDE_CHANNEL === "1";
let bridge;
const mcp = new Server({ name: 'agentmux', version: '0.4.0' }, {
    capabilities: { tools: {}, experimental: { 'claude/channel': {}, 'claude/channel/permission': {} } },
    instructions: 'AgentMux is a trusted local bridge to the user over authenticated SSH. Channel events with chat_id="owner" are user messages. Use the reply tool with chat_id="owner" to return your complete answer. Tool approval decisions are supplied by the human through the permission channel; do not invent or request approvals via the reply tool.',
});
function message(role, text, id = crypto.randomUUID()) {
    state.messages.push({ id, role, text: String(text).slice(0, 65536) });
    while (state.messages.length > 100 || JSON.stringify(state.messages).length > 2 * 1024 * 1024) state.messages.shift();
    state.revision++;
}
function refreshIdentity() {
    try {
        const root = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude');
        const metadata = JSON.parse(readFileSync(join(root, 'sessions', `${nativePID}.json`), 'utf8'));
        if (metadata.pid === nativePID && resolve(metadata.cwd) === resolve(state.cwd)) {
            state.native_session_id = metadata.sessionId;
            if (metadata.sessionId && !state.transcript_path) {
                const encoded = state.cwd.replace(/[^a-zA-Z0-9]/g, '-');
                state.transcript_path = join(root, 'projects', encoded, metadata.sessionId + '.jsonl');
            }
        }
    } catch { /* hooks supply identity when runtime metadata is unavailable */ }
}
function prune() { for (const [id, approval] of approvals) if (Date.now() >= approval.expires) approvals.delete(id); }
mcp.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [{ name: 'reply', description: 'Send the answer to the user in AgentMux.', inputSchema: { type: 'object', properties: { chat_id: { type: 'string', enum: ['owner'] }, text: { type: 'string' } }, required: ['chat_id', 'text'], additionalProperties: false } }] }));
mcp.setRequestHandler(CallToolRequestSchema, async request => {
    if (request.params.name !== 'reply' || request.params.arguments?.chat_id !== 'owner' || typeof request.params.arguments?.text !== 'string') throw invalid('Invalid reply', 400);
    message('assistant', request.params.arguments.text, `reply-${request.params._meta?.progressToken ?? crypto.randomUUID()}`);
    state.busy = false;
    return { content: [{ type: 'text', text: 'Delivered to AgentMux.' }] };
});
const PermissionRequest = z.object({ method: z.literal('notifications/claude/channel/permission_request'), params: z.object({ request_id: z.string(), tool_name: z.string(), description: z.string(), input_preview: z.string() }) });
mcp.setNotificationHandler(PermissionRequest, async ({ params }) => {
    prune();
    if (approvals.size >= 16) return; // keep the normal Mac approval dialog
    approvals.set(params.request_id, { expires: Date.now() + 240000,
        view: { id: params.request_id, title: `允许 ${params.tool_name}？`, detail: `${params.description}\n${params.input_preview}`, options: [], questions: [], kind: params.tool_name === 'AskUserQuestion' ? 'unsupported' : 'confirm' } });
    state.revision++;
});
bridge = await startBridge({
    provider: 'claude', cwd: state.cwd, nativePID,
    snapshot: async () => {
        refreshIdentity(); prune();
        return { messages: state.messages, transcript_path: state.transcript_path, native_session_id: state.native_session_id,
            busy: state.busy, alive: connected && channelEnabled, revision: state.revision, approvals: [...approvals.values()].map(a => a.view),
            commands: [{ name: 'status', description: '查看原会话和 Channel 连接状态', kind: 'command' }],
            capabilities: { message: connected && channelEnabled, abort: false, models: false, approvals: connected && channelEnabled },
            notice: 'Claude Channel：消息与工具审批在原会话处理。需按插件说明启用开发 Channel；终端专有命令不通过 Channel 执行。' };
    },
    action: async action => {
        if (!connected || !channelEnabled) throw invalid('请使用插件的 launch.sh 显式启用 Claude Channel；当前 tmux 窗口仍可直接操作。');
        if (action.action === 'message') {
            if (action.text.startsWith('/')) throw invalid('Channel 不执行终端内置 slash 命令；请使用补全列表中的插件操作。', 400);
            await mcp.notification({ method: 'notifications/claude/channel', params: { content: action.text, meta: { chat_id: 'owner', request_id: action.request_id, source: 'agentmux-ssh' } } });
            message('user', action.text, action.request_id); state.busy = true;
        } else if (action.action === 'approval') {
            prune(); const approval = approvals.get(action.request_id);
            if (!approval || approval.view.kind !== 'confirm') throw invalid('审批已过期，或此请求需要在 Mac 上回答。');
            await mcp.notification({ method: 'notifications/claude/channel/permission', params: { request_id: action.request_id, behavior: action.approved === true ? 'allow' : 'deny' } });
            approvals.delete(action.request_id);
            return { submitted: true }; // the channel has no acknowledgement of the CLI's final decision
        } else if (action.action === 'command' && action.text === 'status') {
            message('system', `Claude Code · ${state.native_session_id || '等待会话登记'}\n${state.cwd}\nChannel 传输已连接。`, 'plugin-status');
        } else throw invalid('Claude Channel 未公开此操作；请在 Mac 中处理。', 400);
    },
    event: async event => {
        if (resolve(event.cwd ?? '') !== resolve(state.cwd)) throw invalid('Hook project mismatch', 400);
        if (typeof event.session_id !== 'string') throw invalid('Session ID required', 400);
        state.native_session_id = event.session_id;
        if (typeof event.transcript_path === 'string') state.transcript_path = event.transcript_path;
        if (event.hook_event_name === 'UserPromptSubmit') state.busy = true;
        if (['Stop', 'SessionEnd'].includes(event.hook_event_name)) { state.busy = false; approvals.clear(); }
        state.revision++;
        return {};
    }, close: async () => { connected = false; await mcp.close(); },
});
mcp.onclose = () => { connected = false; bridge.shutdown().then(() => process.exit(0)); };
mcp.oninitialized = () => { connected = true; };
await mcp.connect(new StdioServerTransport());
// The documented --channels/dev-channel opt-in is also required at launch.
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => bridge.shutdown().then(() => process.exit(0)));
