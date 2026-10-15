// Load with: pi -e /absolute/path/to/integrations/pi/agentmux.ts
// Uses Pi's public extension API without replacing the interactive process.
import { createServer } from "node:http";
import { randomBytes } from "node:crypto";
import { mkdirSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export default function agentmux(pi: ExtensionAPI) {
    let context: ExtensionContext | undefined;
    let draft: unknown;
    let waiting = false;
    let sending = false;
    let mutation = false;
    const delivered = new Map<string, { text: string; accepted: boolean }>();
    const token = randomBytes(32).toString("hex");
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
                    busy: sending || !ctx.isIdle(), waiting, model: ctx.model?.id ?? "",
                    models: ctx.modelRegistry.getAvailable().map(m => ({ id: m.id, name: m.name, provider: m.provider })),
                    can_send: !sending && ctx.isIdle() && !waiting && !ctx.hasPendingMessages() && !ctx.ui.getEditorText(),
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
                if (action.action === "message") {
                    if (typeof action.text !== "string" || !action.text.trim() || Buffer.byteLength(action.text) > 65536 || typeof action.request_id !== "string" || !action.request_id || action.request_id.length > 128) {
                        reply(400, { error: "Message and request_id required" }); return;
                    }
                    const previous = delivered.get(action.request_id);
                    if (previous !== undefined) {
                        reply(previous.text === action.text && previous.accepted ? 200 : 409, { accepted: previous.accepted, error: "Inspect the previous delivery before retrying" }); return;
                    }
                    if (delivered.size >= 1024 || sending || !ctx.isIdle() || waiting || ctx.hasPendingMessages() || ctx.ui.getEditorText()) {
                        reply(409, { error: "Pi is busy, waiting for a dialog, or the Mac editor has a draft" }); return;
                    }
                    sending = true;
                    delivered.set(action.request_id, { text: action.text, accepted: false });
                    pi.sendUserMessage(action.text);
                    delivered.set(action.request_id, { text: action.text, accepted: true });
                } else if (action.action === "abort") { ctx.abort(); sending = false; }
                else if (action.action === "model") {
                    if (!ctx.isIdle() || sending || waiting) { reply(409, { error: "Wait for Pi to become idle" }); return; }
                    const model = ctx.modelRegistry.getAvailable().find(m => m.id === action.model && m.provider === action.provider);
                    if (!model || !(await pi.setModel(model))) { reply(400, { error: "Model is unavailable" }); return; }
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
        writeFileSync(temporary, JSON.stringify({ version: 1, pid: process.pid, port: address.port, token, cwd: context.cwd }), { mode: 0o600 });
        renameSync(temporary, manifest);
    };
    pi.on("session_start", async (_, ctx) => {
        context = ctx; draft = undefined; sending = false; waiting = false;
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
    pi.on("ui_prompt_start", () => { waiting = true; });
    pi.on("ui_prompt_end", () => { waiting = false; });
    pi.on("session_shutdown", async () => {
        context = undefined;
        server.closeAllConnections(); server.close();
        try { unlinkSync(manifest); } catch { /* already removed */ }
    });
}
