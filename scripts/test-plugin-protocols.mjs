// Test the shipped plugins with official MCP SDK and a deterministic Codex proxy fixture.
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, readdir, rm, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { Client } from '../dist/plugins/agentmux-claude/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
import { StdioClientTransport } from '../dist/plugins/agentmux-claude/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js';
import { z } from '../dist/plugins/agentmux-claude/node_modules/zod/index.js';

const repo = resolve(import.meta.dirname, '..');
const temporary = await mkdtemp(join(tmpdir(), 'agentmux-plugin-protocol-'));
const cwd = await import('node:fs/promises').then(async fs => { const path=join(temporary,'project'); await fs.mkdir(path); return path; });
const directory = join(temporary, 'bridges');
const env = { ...process.env, AGENTMUX_BRIDGE_DIR: directory, CLAUDE_CONFIG_DIR: join(temporary, 'claude-home'), AGENTMUX_CLAUDE_CHANNEL: '1' };
const children = [];
async function wait(operation) { for(let i=0;i<150;i++) { const value=await operation(); if(value) return value; await new Promise(r=>setTimeout(r,20)); } throw new Error('Fixture state timeout'); }
async function manifest(provider) {
    return wait(async()=> { try { for(const name of await readdir(directory)) { if(!name.endsWith('.json')) continue; const value=JSON.parse(await readFile(join(directory,name),'utf8')); if(value.provider===provider) return value; } } catch {} });
}
async function http(m,path,value) {
    const response=await fetch(`http://127.0.0.1:${m.port}${path}`,{method:value===undefined?'GET':'POST',headers:{Authorization:`Bearer ${m.token}`,'Content-Type':'application/json'},body:value===undefined?undefined:JSON.stringify(value),signal:AbortSignal.timeout(15000)});
    return {status:response.status,value:await response.json()};
}
function launch(file, value, extra={}) {
    const process=spawn(globalThis.process.execPath,[file],{cwd,env:{...env,...extra},stdio:['pipe','pipe','pipe']});children.push(process);
    let stdout='',stderr='';process.stdout.on('data',b=>stdout+=b);process.stderr.on('data',b=>stderr+=b);
    const done=new Promise((resolvePromise,reject)=>{process.on('error',reject);process.on('exit',code=>resolvePromise({code,stdout,stderr}));});
    if(value!==undefined) process.stdin.end(JSON.stringify(value));
    return {process,done};
}
let client,transport,codexManifest,daemon,uploadRoot;
try {
    const notifications=[];
    client=new Client({name:'claude-code-fixture',version:'1.0.0'},{capabilities:{}});
    client.setNotificationHandler(z.object({method:z.literal('notifications/claude/channel'),params:z.any()}),async value=>notifications.push(value));
    client.setNotificationHandler(z.object({method:z.literal('notifications/claude/channel/permission'),params:z.any()}),async value=>notifications.push(value));
    transport=new StdioClientTransport({command:process.execPath,args:[join(repo,'dist/plugins/agentmux-claude/server.mjs')],cwd,env,stderr:'pipe'});
    await client.connect(transport);
    const claude=await manifest('claude');
    assert.ok(client.getServerCapabilities().experimental['claude/channel/permission']);
    await wait(async()=> (await http(claude,'/snapshot')).value.alive);
    const claudeAction=action=>http(claude,'/actions',{agent_pid:claude.pid,...action});
    assert.equal((await fetch(`http://127.0.0.1:${claude.port}/snapshot`)).status,401);
    const send={action:'message',text:'Hello original Claude session',request_id:'claude-once'};
    assert.equal((await claudeAction(send)).status,200);assert.equal((await claudeAction(send)).status,200);
    await wait(()=>notifications.some(n=>n.method==='notifications/claude/channel'));
    assert.equal(notifications.filter(n=>n.method==='notifications/claude/channel').length,1);
    await client.callTool({name:'reply',arguments:{chat_id:'owner',text:'Reply from original Claude'}});
    assert.ok((await http(claude,'/snapshot')).value.messages.some(m=>m.text==='Reply from original Claude'));
    await client.notification({method:'notifications/claude/channel/permission_request',params:{request_id:'abcde',tool_name:'Bash',description:'Write fixture file',input_preview:'{"command":"write fixture"}'}});
    await wait(async()=> (await http(claude,'/snapshot')).value.approvals.length===1);
    assert.equal((await claudeAction({action:'approval',request_id:'abcde',approved:true})).status,200);
    await wait(()=>notifications.some(n=>n.method==='notifications/claude/channel/permission'));
    assert.deepEqual(notifications.find(n=>n.method==='notifications/claude/channel/permission').params,{request_id:'abcde',behavior:'allow'});
    assert.equal((await claudeAction({action:'approval',request_id:'abcde',approved:true})).status,409);
    assert.equal((await claudeAction({...send,agent_pid:claude.pid+1,request_id:'wrong-pid'})).status,409);
    console.log('PASS: Claude official MCP channel: same-session input/reply, tools approval notifications, authentication, deduplication, stale approvals and PID rejection');

    const fixture=join(temporary,'codex-fixture');const stateFile=join(temporary,'codex-state.json');const logFile=join(temporary,'codex-operations.jsonl');
    await writeFile(stateFile,JSON.stringify({busy:false}));
    await writeFile(fixture,`#!/usr/bin/env node\nimport fs from 'node:fs';import readline from 'node:readline';const args=process.argv.slice(2);const log=value=>fs.appendFileSync(${JSON.stringify(logFile)},JSON.stringify(value)+'\\n');if(args[0]==='queue'){log({method:'queue',args});fs.writeFileSync(${JSON.stringify(stateFile)},JSON.stringify({busy:true}));process.exit(0)}if(args[0]!=='app-server'||args[1]!=='proxy')process.exit(2);readline.createInterface({input:process.stdin}).on('line',line=>{let request=JSON.parse(line);if(!request.id)return;log({method:request.method,params:request.params});let result={};if(request.method==='thread/read')result={thread:{id:'fixture-thread',cwd:${JSON.stringify(cwd)},status:{type:JSON.parse(fs.readFileSync(${JSON.stringify(stateFile)})).busy?'active':'idle'}}};if(request.method==='model/list')result={data:[{model:'model-a',displayName:'Model A'},{model:'model-b',displayName:'Model B'}]};if(request.method==='thread/turns/list')result={data:[{id:'turn-fixture',status:'inProgress'}]};if(request.method==='turn/interrupt')fs.writeFileSync(${JSON.stringify(stateFile)},JSON.stringify({busy:false}));process.stdout.write(JSON.stringify({id:request.id,result})+'\\n')});\n`);
    await chmod(fixture,0o700);
    const hookFile=join(repo,'dist/plugins/agentmux-codex/hook.mjs');
    const hookEvent={session_id:'fixture-thread',cwd,model:'model-a',hook_event_name:'SessionStart'};
    const starts=Array.from({length:5},()=>launch(hookFile,hookEvent,{AGENTMUX_CODEX_BIN:fixture}));
    assert.ok((await Promise.all(starts.map(s=>s.done))).every(s=>s.code===0));
    codexManifest=await manifest('codex');
    const codexAction=action=>http(codexManifest,'/actions',{agent_pid:codexManifest.pid,...action});
    let snapshot=(await http(codexManifest,'/snapshot')).value;assert.equal(snapshot.alive,true);assert.equal(snapshot.models.length,2);
    let initialized=(await readFile(logFile,'utf8')).trim().split('\n').map(JSON.parse);
    assert.equal(initialized.filter(o=>o.method==='initialize').length,1,'Concurrent hooks must share one bridge');
    const portProbe=createServer();await new Promise(resolve=>portProbe.listen(0,'127.0.0.1',resolve));const port=portProbe.address().port;await new Promise(resolve=>portProbe.close(resolve));
    const config=join(temporary,'config.json'),token='fixture-private-api-token-'.repeat(3);
    await writeFile(config,JSON.stringify({revision:0,roots:[cwd],default_directory:cwd,agents:{codex:'codex',claude:'claude',pi:'pi'}}));
    daemon=spawn(join(repo,'target/debug/agentmuxd'),[],{cwd,env:{...env,AGENTMUX_CONFIG:config,AGENTMUX_STATE:join(temporary,'state'),AGENTMUX_DISCOVERY:join(temporary,'discovery.json'),AGENTMUX_TOKEN:token,AGENTMUX_API_PORT:String(port),AGENTMUX_SSH_DISABLED:'1'},stdio:'ignore'});
    async function api(path,value) {
        const response=await fetch(`http://127.0.0.1:${port}/v1/plugins${path}`,{method:value===undefined?'GET':'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:value===undefined?undefined:JSON.stringify(value),signal:AbortSignal.timeout(15000)});
        const text=await response.text();let parsed;try{parsed=JSON.parse(text)}catch{parsed=text}
        return {status:response.status,value:parsed};
    }
    const listed=await wait(async()=>{try {const result=await api('');return result.status===200&&result.value.length===2?result.value:null;}catch{}});
    for(const provider of ['claude','codex']) {
        const session=listed.find(s=>s.command===provider);assert.ok(session);
        const read=await api(`/${session.id}/chat`);assert.equal(read.status,200);assert.equal(read.value.agent_pid,session.agent_pid);assert.equal(read.value.capabilities.message,true);
        assert.equal('transcript_path' in read.value,false);
        assert.equal((await api(`/${session.id}/actions`,{action:'command',text:'status',request_id:`${provider}-status-api`,agent_pid:session.agent_pid})).status,200);
        assert.equal((await api(`/${session.id}/actions`,{action:'message',text:'wrong pid',request_id:'wrong-api',agent_pid:session.agent_pid+1})).status,409);
    }
    console.log('PASS: externally started Claude/Codex plugins discovered through Rust API; iOS-shaped snapshots, same-process commands and PID checks');
    assert.equal((await codexAction({action:'model',model:'model-b'})).status,200);
    const prompt={action:'message',text:'Continue this exact existing Codex session',request_id:'codex-once'};
    assert.equal((await codexAction(prompt)).status,200);assert.equal((await codexAction(prompt)).status,200);
    let operations=(await readFile(logFile,'utf8')).trim().split('\n').map(JSON.parse);
    assert.equal(operations.filter(o=>o.method==='queue').length,1);
    assert.ok(operations.find(o=>o.method==='queue').args.includes('model-b'));
    assert.equal((await codexAction({action:'abort'})).status,200);
    assert.equal((await codexAction({action:'command',text:'compact',request_id:'compact'})).status,200);
    const permission=launch(hookFile,{...hookEvent,hook_event_name:'PermissionRequest',turn_id:'turn-fixture',tool_name:'Bash',tool_input:{command:'touch fixture'}},{AGENTMUX_CODEX_BIN:fixture});
    snapshot=await wait(async()=>{const s=(await http(codexManifest,'/snapshot')).value;return s.approvals.length?s:null});
    const id=snapshot.approvals[0].id;
    assert.equal((await codexAction({action:'approval',request_id:id,approved:false})).status,200);
    const verdict=await permission.done;assert.equal(verdict.code,0);assert.equal(JSON.parse(verdict.stdout).hookSpecificOutput.decision.behavior,'deny');
    assert.equal((await codexAction({action:'approval',request_id:id,approved:true})).status,409);
    // Exercise image forwarding through the authenticated public API, not a forged bridge path.
    const image = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aFioAAAAASUVORK5CYII=', 'base64');
    const fileID = crypto.randomUUID();
    const uploaded = await fetch(`http://127.0.0.1:${port}/v1/attachments/${fileID}?name=fixture.png`, {method:'PUT', headers:{Authorization:`Bearer ${token}`}, body:image});
    assert.equal(uploaded.status,200);
    const receipt = await uploaded.json();
    assert.ok(receipt.path.startsWith('/tmp/agentmux-uploads-'));
    uploadRoot = dirname(dirname(dirname(receipt.path)));
    const claudeSession = listed.find(s=>s.command==='claude');
    const imageAction = {action:'message',text:'Inspect this image',request_id:'claude-image-once',agent_pid:claudeSession.agent_pid,attachments:[fileID],uploaded_files:[{id:'forged',path:'/etc/hosts',mime_type:'image/png'}]};
    assert.equal((await api(`/${claudeSession.id}/actions`,imageAction)).status,200);
    assert.equal((await api(`/${claudeSession.id}/actions`,imageAction)).status,200);
    await wait(()=>notifications.some(n=>n.params?.meta?.request_id==='claude-image-once'));
    assert.equal(notifications.filter(n=>n.params?.meta?.request_id==='claude-image-once').length,1);
    const content = await client.callTool({name:'read_attachment',arguments:{file_id:fileID}});
    assert.equal(content.content[0].type,'image');
    assert.equal(content.content[0].mimeType,'image/png');
    assert.deepEqual(Buffer.from(content.content[0].data,'base64'),image);
    await assert.rejects(()=>client.callTool({name:'read_attachment',arguments:{file_id:'forged'}}));
    await client.callTool({name:'reply',arguments:{chat_id:'owner',text:'Image fixture received'}});
    const codexSession = listed.find(s=>s.command==='codex');
    const codexImage = {...imageAction,agent_pid:codexSession.agent_pid,request_id:'codex-image-once'};
    assert.equal((await api(`/${codexSession.id}/actions`,codexImage)).status,200);
    assert.equal((await api(`/${codexSession.id}/actions`,codexImage)).status,200);
    operations=(await readFile(logFile,'utf8')).trim().split('\n').map(JSON.parse);
    const imageQueues=operations.filter(o=>o.method==='queue'&&o.args.includes('--image'));
    assert.equal(imageQueues.length,1);
    assert.equal(imageQueues[0].args[imageQueues[0].args.indexOf('--image')+1],receipt.path);
    assert.ok(!imageQueues[0].args.includes('/etc/hosts'));
    assert.ok(imageQueues[0].args.includes('fixture-thread'));
    assert.equal((await codexAction({action:'abort'})).status,200);
    console.log('PASS: /tmp uploads forwarded to original Codex queue images and Claude MCP image tools; exact bytes, deduplication and forged-path rejection');
    const previousPID=codexManifest.pid;process.kill(previousPID,'SIGKILL');
    await wait(async()=>{try{await http(codexManifest,'/health');return false}catch{return true}});
    const recovered=launch(hookFile,hookEvent,{AGENTMUX_CODEX_BIN:fixture});assert.equal((await recovered.done).code,0);
    codexManifest=await manifest('codex');assert.notEqual(codexManifest.pid,previousPID,'A stale bridge must recover on a new hook');
    const ended=launch(hookFile,{...hookEvent,hook_event_name:'SessionEnd'},{AGENTMUX_CODEX_BIN:fixture});assert.equal((await ended.done).code,0);
    console.log('PASS: Codex packaged hook/plugin: original thread queue, model override, compact, cancel, explicit permission decision, concurrent hooks, stale bridge recovery and PID rejection; no independent thread/start or resume');
    operations=(await readFile(logFile,'utf8')).trim().split('\n').map(JSON.parse);assert.ok(!operations.some(o=>['thread/start','thread/resume'].includes(o.method)));
} finally {
    if(daemon) {daemon.kill();await new Promise(resolve=>daemon.exitCode!==null?resolve():daemon.once('exit',resolve));}
    await client?.close();await transport?.close();
    for(const child of children) if(child.exitCode===null) child.kill();
    if(codexManifest) { try {process.kill(codexManifest.pid,'SIGTERM')}catch{} }
    if(uploadRoot) await rm(uploadRoot,{recursive:true,force:true});
    await rm(temporary,{recursive:true,force:true});
}
