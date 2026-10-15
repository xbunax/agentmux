// Load with: pi -e /absolute/path/to/integrations/pi/agentmux.ts
// Uses Pi's public extension API without replacing the interactive process.
import { createServer } from "node:http";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdirSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { readFile } from "node:fs/promises";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
class DialogRelay {
    private pending = new Map<string, { view: any; finish: (value: any) => void }>();
    private originals = new Map<any, Map<string, { original: any; wrapped: any }>>();
    get views() { return [...this.pending.values()].map(p => p.view); }
    wrap(ui: any) {
        if (this.originals.has(ui)) return;
        const methods = new Map<string, { original: any; wrapped: any }>();
        this.originals.set(ui, methods);
        // These are UI primitives with a documented AbortSignal, not scenario names.
        for (const kind of ["select", "confirm", "input"]) {
            const original = ui[kind];
            if (typeof original !== "function") continue;
            const relay = this;
            const wrapped = function(title: string, argument: any, options: any = {}) {
                if (relay.pending.size >= 16) return original.call(ui, title, argument, options);
                const id = randomUUID(), controller = new AbortController();
                const signal = options.signal ? AbortSignal.any([options.signal, controller.signal]) : controller.signal;
                const view = { id, kind, title, detail: kind === "select" ? "" : String(argument ?? ""), options: kind === "select" ? [...argument] : [], questions: [] };
                return new Promise((resolve, reject) => {
                    let settled = false;
                    const finish = (value: any) => {
                        if (settled) return;
                        settled = true; relay.pending.delete(id); resolve(value);
                        controller.abort(); // dismiss the original SDK dialog after resolving once
                    };
                    relay.pending.set(id, { view, finish });
                    try {
                        Promise.resolve(original.call(ui, title, argument, { ...options, signal })).then(finish, error => {
                            if (!settled) { settled = true; relay.pending.delete(id); reject(error); }
                        });
                    } catch (error) { settled = true; relay.pending.delete(id); reject(error); }
                });
            };
            methods.set(kind, { original, wrapped }); ui[kind] = wrapped;
        }
    }
    answer(id: string, approved: boolean, value: string): number {
        const pending = this.pending.get(id);
        if (!pending) return 409;
        if (approved && (typeof value !== "string" || value.length > 8192 || (pending.view.kind === "select" && !pending.view.options.includes(value)))) return 400;
        pending.finish(pending.view.kind === "confirm" ? approved : approved ? value : undefined);
        return 200;
    }
    close() {
        for (const pending of this.pending.values()) pending.finish(pending.view.kind === "confirm" ? false : undefined);
        for (const [ui, methods] of this.originals) for (const [name, {original, wrapped}] of methods) if (ui[name] === wrapped) ui[name] = original;
        this.originals.clear();
    }
}


export default function agentmux(pi: ExtensionAPI) {
    let context: ExtensionContext | undefined;
    let draft: unknown;
    let waiting = false;
    let waitingTitle = "";
    const dialogs = new DialogRelay();
    let sending = false;
    let mutation = false;
    let sessionInfo = "";
    const delivered = new Map<string, { text: string; accepted: boolean }>();
    const token = randomBytes(32).toString("hex");
    const bridgeID = randomUUID();
    const directory = process.env.AGENTMUX_BRIDGE_DIR ?? join(homedir(), "Library/Application Support/AgentMux/bridges");
    const manifest = join(directory, `pi-${process.pid}.json`);
    let started = false;
    const server = createServer(async (request, response) => {
        const reply = (status: number, value: unknown) => {
            response.writeHead(status, { "Content-Type": "application/json" });
            response.end(JSON.stringify(value));
        };
        if (request.headers.authorization !== `Bearer ${token}`) { reply(401, { error: "Authentication required" }); return; }
        const ctx = context;
        if (!ctx) { reply(503, { error: "Pi session is not ready" }); return; }
        try {
            if (request.method === "GET" && request.url === "/snapshot") {
                const entries: any[] = ctx.sessionManager.getBranch().slice(-600);
                if (draft) entries.push({ type: "message", id: "agentmux-stream", parentId: entries.at(-1)?.id ?? null, message: draft });
                reply(200, {
                    entries, pid: process.pid, cwd: ctx.cwd, session_id: ctx.sessionManager.getSessionId(),
                    bridge_id: bridgeID, bridge_pid: process.pid, native_session_id: ctx.sessionManager.getSessionId(),
                    messages: [], alive: true, approvals: dialogs.views.length ? dialogs.views : waiting ? [{id:"local-dialog",kind:"unsupported",title:waitingTitle || "Pi 等待交互",detail:"此自定义界面未公开结构化输入，请在 Mac 上处理。",options:[],questions:[]}] : [], error: null, revision: 0, source: "pi-plugin",
                    commands: [
                        { name: "model", description: "选择当前会话的模型", kind: "model" },
                        { name: "compact", description: "压缩当前会话上下文", kind: "command" },
                        { name: "session", description: "查看当前会话信息", kind: "command" },
                        ...(pi.getCommands?.() ?? []).filter(c => !["model", "compact", "session"].includes(c.name)).map(c => ({ name: c.name, description: c.description ?? "Pi 命令", kind: "command" })),
                    ],
                    capabilities: { message: !sending && ctx.isIdle() && !waiting && !dialogs.views.length && !ctx.hasPendingMessages() && !ctx.ui.getEditorText(), abort: true, models: true, approvals: true },
                    notice: waiting ? "Pi 正在等待 Mac 上的扩展对话框。" : sessionInfo || "已通过插件连接原来的 Pi 会话。",
                    busy: sending || !ctx.isIdle(), waiting, model: ctx.model?.id ?? "",
                    models: ctx.modelRegistry.getAvailable().map(m => ({ id: m.id, name: m.name, provider: m.provider })),
                    can_send: !sending && ctx.isIdle() && !waiting && !dialogs.views.length && !ctx.hasPendingMessages() && !ctx.ui.getEditorText(),
                });
                return;
            }
            if (request.method !== "POST" || request.url !== "/actions") { reply(404, { error: "Unknown endpoint" }); return; }
            let size = 0;
            const chunks: Buffer[] = [];
            for await (const chunk of request) {
                size += chunk.length;
                if (size > 128 * 1024) { reply(413, { error: "Action too large" }); return; }
                chunks.push(chunk);
            }
            const action = JSON.parse(Buffer.concat(chunks).toString("utf8"));
            if (action.agent_pid !== process.pid) { reply(409, { error: "Pi process changed" }); return; }
            if (mutation) { reply(409, { error: "Another action is in progress" }); return; }
            mutation = true;
            try {
                if (action.action === "approval") {
                    const status = dialogs.answer(action.request_id, action.approved === true, action.text ?? "");
                    reply(status, status === 200 ? {accepted:true} : {error:"交互已结束，或答案不在当前表单中"}); return;
                } else if (action.action === "message") {
                    if (typeof action.text !== "string" || !action.text.trim() || Buffer.byteLength(action.text) > 65536 || typeof action.request_id !== "string" || !action.request_id || action.request_id.length > 128) {
                        reply(400, { error: "Message and request_id required" }); return;
                    }
                    const previous = delivered.get(action.request_id);
                    if (previous !== undefined) {
                        reply(previous.text === action.text && previous.accepted ? 200 : 409, { accepted: previous.accepted, error: "Inspect the previous delivery before retrying" }); return;
                    }
                    if (delivered.size >= 1024 || sending || !ctx.isIdle() || waiting || dialogs.views.length || ctx.hasPendingMessages() || ctx.ui.getEditorText()) {
                        reply(409, { error: "Pi is busy, waiting for a dialog, or the Mac editor has a draft" }); return;
                    }
                    const images = [];
                    for (const file of action.uploaded_files ?? []) {
                        if (typeof file.mime_type === "string" && file.mime_type.startsWith("image/")) {
                            const data = await readFile(file.path);
                            if (data.length > 8 * 1024 * 1024) throw new Error("Attachment too large");
                            images.push({ type: "image" as const, data: data.toString("base64"), mimeType: file.mime_type });
                        }
                    }
                    // File reads yield; recheck the original editor before submitting any input.
                    if (sending || !ctx.isIdle() || waiting || dialogs.views.length || ctx.hasPendingMessages() || ctx.ui.getEditorText()) {
                        reply(409, { error: "Pi input state changed while loading attachments" }); return;
                    }
                    sending = true;
                    delivered.set(action.request_id, { text: action.text, accepted: false });
                    pi.sendUserMessage(images.length ? [{ type: "text", text: action.text }, ...images] : action.text);
                    delivered.set(action.request_id, { text: action.text, accepted: true });
                } else if (action.action === "abort") { ctx.abort(); sending = false; }
                else if (action.action === "model") {
                    if (!ctx.isIdle() || sending || waiting) { reply(409, { error: "Wait for Pi to become idle" }); return; }
                    const model = ctx.modelRegistry.getAvailable().find(m => m.id === action.model && m.provider === action.provider);
                    if (!model || !(await pi.setModel(model))) { reply(400, { error: "Model is unavailable" }); return; }
                } else if (action.action === "command") {
                    if (!ctx.isIdle() || sending || waiting || ctx.hasPendingMessages() || ctx.ui.getEditorText()) { reply(409, { error: "Pi is busy or the Mac editor has a draft" }); return; }
                    if (typeof action.text !== "string" || action.text.length > 65536 || typeof action.request_id !== "string" || !action.request_id) { reply(400, { error: "Command and request_id required" }); return; }
                    const key = `command-${action.request_id}`;
                    const previous = delivered.get(key);
                    if (previous) { reply(previous.accepted && previous.text === action.text ? 200 : 409, { accepted: previous.accepted }); return; }
                    if (delivered.size >= 1024) { reply(409, { error: "Session request limit reached" }); return; }
                    const name = action.text.split(/\s/)[0];
                    if (!["compact", "session"].includes(name) && !(pi.getCommands?.() ?? []).some(c => c.name === name)) { reply(400, { error: "Command not advertised by Pi" }); return; }
                    delivered.set(key, { text: action.text, accepted: false });
                    if (name === "compact") { ctx.compact(); }
                    else if (name === "session") { sessionInfo = `Pi · ${ctx.sessionManager.getSessionId()}\n${ctx.cwd}`; }
                    else pi.sendUserMessage("/" + action.text, { expandPromptTemplates: true });
                    delivered.set(key, { text: action.text, accepted: true });
                } else { reply(400, { error: "Unsupported Pi action" }); return; }
                reply(200, { accepted: true });
            } finally { mutation = false; }
        } catch { reply(500, { error: "Pi bridge action failed; inspect the session before retrying" }); }
    });
    server.requestTimeout = 10000;
    server.headersTimeout = 5000;
    const publish = () => {
        const address = server.address();
        if (!context || !address || typeof address === "string") return;
        mkdirSync(directory, { recursive: true, mode: 0o700 });
        const temporary = `${manifest}.tmp`;
        writeFileSync(temporary, JSON.stringify({ version: 2, provider: "pi", id: bridgeID, pid: process.pid, agent_pid: process.pid, tmux_pane: process.env.TMUX_PANE ?? null, port: address.port, token, cwd: context.cwd }), { mode: 0o600 });
        renameSync(temporary, manifest);
    };
    pi.on("session_start", async (_, ctx) => {
        dialogs.wrap(ctx.ui);
        context = ctx; draft = undefined; sending = false; waiting = false; sessionInfo = "";
        if (!started) {
            started = true;
            server.on("error", () => ctx.ui.notify("AgentMux bridge could not start", "error"));
            server.listen(0, "127.0.0.1", publish);
        } else publish();
    });
    pi.on("message_update", (event, ctx) => { context = ctx; draft = event.message; });
    pi.on("message_end", (_, ctx) => { context = ctx; draft = undefined; });
    pi.on("agent_start", (_, ctx) => { context = ctx; sending = false; });
    pi.on("agent_settled", (_, ctx) => { context = ctx; sending = false; draft = undefined; });
    pi.on("model_select", (_, ctx) => { context = ctx; });
    pi.on("ui_prompt_start", event => { waiting = true; waitingTitle = event.title ?? ""; });
    pi.on("ui_prompt_end", () => { waiting = false; waitingTitle = ""; });
    pi.on("session_shutdown", async () => {
        context = undefined;
        dialogs.close();
        server.closeAllConnections(); server.close();
        try { unlinkSync(manifest); } catch { /* already removed */ }
    });
}
