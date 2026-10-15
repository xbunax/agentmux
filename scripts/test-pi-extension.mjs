// Exercise the actual extension with a public-API fixture; no Pi auth or model calls.
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, stat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import extension from '../integrations/pi/agentmux.ts';

const directory = await mkdtemp(join(tmpdir(), 'agentmux-pi-'));
process.env.AGENTMUX_BRIDGE_DIR = directory;
const handlers = new Map();
let idle = true, editor = '', sends = 0, aborted = 0, chosen = '';
let imageReceived, desktopResolve;
const model = { id: 'test-model', name: 'Fixture', provider: 'fixture' };
const ctx = {
    cwd: '/fixture', model,
    ui: { getEditorText: () => editor, notify() {},
        select(title, values, opts) { return new Promise(resolve=>{desktopResolve=resolve;opts.signal?.addEventListener('abort',()=>resolve(undefined),{once:true});}); },
        confirm(title, message, opts) { return new Promise(resolve=>{desktopResolve=resolve;opts.signal?.addEventListener('abort',()=>resolve(false),{once:true});}); },
        input(title, placeholder, opts) { return new Promise(resolve=>{desktopResolve=resolve;opts.signal?.addEventListener('abort',()=>resolve(undefined),{once:true});}); },
    },
    sessionManager: { getBranch: () => [{ type: 'message', id: 'first', parentId: null, message: { role: 'user', content: 'Hello' } }], getSessionId: () => 'fixture-session' },
    modelRegistry: { getAvailable: () => [model] },
    isIdle: () => idle, hasPendingMessages: () => false,
    abort: () => { aborted++; idle = true; },
};
const api = {
    on: (name, handler) => handlers.set(name, handler),
    sendUserMessage: text => { if(Array.isArray(text)) imageReceived=text; else assert.equal(text, 'from phone'); sends++; idle = false; },
    setModel: async value => { chosen = value.id; return true; },
};
extension(api);
try {
    await handlers.get('session_start')({}, ctx);
    const path = join(directory, `pi-${process.pid}.json`);
    let manifest;
    for (let attempt = 0; attempt < 100; attempt++) {
        try { manifest = JSON.parse(await readFile(path, 'utf8')); break; }
        catch { await new Promise(resolve => setTimeout(resolve, 10)); }
    }
    assert.ok(manifest);
    assert.equal((await stat(path)).mode & 0o777, 0o600);
    const origin = `http://127.0.0.1:${manifest.port}`;
    const headers = { Authorization: `Bearer ${manifest.token}`, 'Content-Type': 'application/json' };
    const action = value => fetch(origin + '/actions', { method: 'POST', headers, body: JSON.stringify({ agent_pid: process.pid, ...value }) });
    assert.equal((await fetch(origin + '/snapshot')).status, 401);
    let snapshot = await (await fetch(origin + '/snapshot', { headers })).json();
    assert.equal(snapshot.entries[0].message.content, 'Hello');
    assert.equal(snapshot.can_send, true);
    editor = 'Mac draft';
    assert.equal((await action({ action: 'message', text: 'from phone', request_id: 'draft' })).status, 409);
    editor = '';
    handlers.get('ui_prompt_start')({});
    assert.equal((await action({ action: 'message', text: 'from phone', request_id: 'dialog' })).status, 409);
    handlers.get('ui_prompt_end')({});
    const message = { action: 'message', text: 'from phone', request_id: 'once' };
    assert.equal((await action(message)).status, 200);
    assert.equal((await action(message)).status, 200);
    assert.equal(sends, 1);
    assert.equal((await action({ ...message, text: 'changed' })).status, 409);
    assert.equal((await action({ ...message, request_id: 'twice' })).status, 409);
    handlers.get('message_update')({ message: { role: 'assistant', content: [{ type: 'text', text: 'streaming' }] } }, ctx);
    snapshot = await (await fetch(origin + '/snapshot', { headers })).json();
    assert.equal(snapshot.entries.at(-1).message.content[0].text, 'streaming');
    assert.equal((await action({ action: 'abort' })).status, 200);
    assert.equal(aborted, 1);
    handlers.get('agent_settled')({}, ctx);
    assert.equal((await action({ action: 'model', model: model.id, provider: model.provider })).status, 200);
    assert.equal(chosen, model.id);
    assert.equal((await action({ action: 'model', model: 'unavailable', provider: 'fixture' })).status, 400);
    assert.equal((await action({ action: 'abort', agent_pid: process.pid + 1 })).status, 409);
    const selection = ctx.ui.select('Unseen deployment destination', ['lunar-base','underwater'], {});
    snapshot=await (await fetch(origin+'/snapshot',{headers})).json();
    let dialog=snapshot.approvals[0]; assert.equal(dialog.kind,'select'); assert.equal(snapshot.can_send,false);
    assert.equal((await action({action:'approval',request_id:dialog.id,approved:true,text:'not-offered'})).status,400);
    assert.equal((await action({action:'approval',request_id:dialog.id,approved:true,text:'underwater'})).status,200);
    assert.equal(await selection,'underwater');
    assert.equal((await action({action:'approval',request_id:dialog.id,approved:true,text:'lunar-base'})).status,409);
    const confirmation=ctx.ui.confirm('Unseen permission', 'Approve a fixture action?', {});
    snapshot=await (await fetch(origin+'/snapshot',{headers})).json();dialog=snapshot.approvals[0];
    assert.equal((await action({action:'approval',request_id:dialog.id,approved:false})).status,200);assert.equal(await confirmation,false);
    const input=ctx.ui.input('Unseen question', 'Reply here', {});
    snapshot=await (await fetch(origin+'/snapshot',{headers})).json();dialog=snapshot.approvals[0];
    desktopResolve('Answered on Mac');assert.equal(await input,'Answered on Mac');
    assert.equal((await action({action:'approval',request_id:dialog.id,approved:true,text:'late phone response'})).status,409);
    const cancelled=new AbortController(); const timeout=ctx.ui.input('Cancelled elsewhere', '', {signal:cancelled.signal});
    cancelled.abort();assert.equal(await timeout,undefined);
    assert.equal((await (await fetch(origin+'/snapshot',{headers})).json()).approvals.length,0);
    console.log('PASS: public Pi SDK dialogs: arbitrary select/confirm/input, original continuations, Mac/mobile races, signal cancellation, invalid answers and stale IDs');
    const imagePath=join(directory,'image.png');
    const imageMessage={action:'message',text:'from phone',request_id:'image-message',uploaded_files:[{path:imagePath,mime_type:'image/png'}]};
    assert.equal((await action(imageMessage)).status,500);
    assert.equal((await (await fetch(origin+'/snapshot',{headers})).json()).can_send,true,'Failed file preparation must not lock the original Pi editor');
    await writeFile(imagePath,Buffer.from('fixture-image'));
    assert.equal((await action(imageMessage)).status,200);
    assert.equal(imageReceived[0].text,'from phone');assert.equal(imageReceived[1].mimeType,'image/png');
    assert.equal(Buffer.from(imageReceived[1].data,'base64').toString(),'fixture-image');
    console.log('PASS: Pi same-process SDK bridge authentication, private discovery, conversation/streaming, drafts/dialog protection, send deduplication, cancellation, model selection and PID binding');
} finally {
    await handlers.get('session_shutdown')({}, ctx);
    await rm(directory, { recursive: true, force: true });
}
