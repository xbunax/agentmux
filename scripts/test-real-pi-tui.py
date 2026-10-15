#!/usr/bin/env python3
"""Real Pi TUI: manually launch before AgentMux, then change its model via API.

Offline, isolated tmux/config and dummy local models; no model request is sent.
"""
import json
import sys
import os
import secrets
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
pi, tmux = shutil.which('pi'), shutil.which('tmux')
assert pi and tmux
sdk_dialogs = "--sdk-dialogs" in sys.argv
narrow = "--narrow" in sys.argv
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='agentmux-real-pi-') as temporary:
    root = Path(temporary).resolve(); home = root / 'pi-home'; home.mkdir()
    (home / 'models.json').write_text(json.dumps({'providers': {'fixture': {'baseUrl': 'http://127.0.0.1:9/v1', 'api': 'openai-completions', 'apiKey': 'dummy', 'models': [{'id': 'model-a'}, {'id': 'model-b'}, {'id': 'model-c'}] + [{'id':f'extra-model-{i:02}'} for i in range(70)]}}}))
    (home / 'settings.json').write_text(json.dumps({'defaultProvider': 'fixture', 'defaultModel': 'model-a', 'quietStartup': True}))
    server = 'agentmux-real-pi-' + secrets.token_hex(6)
    wrapper = root / 'tmux'; wrapper.write_text(f'#!/bin/sh\nexec {shlex.quote(tmux)} -f /dev/null -L {shlex.quote(server)} "$@"\n'); wrapper.chmod(0o700)
    def run(*args): return subprocess.check_output([str(wrapper), *args], text=True).strip()
    launcher = root / 'launch-pi'
    launcher.write_text('#!/bin/sh\nexport PI_CODING_AGENT_DIR=' + shlex.quote(str(home)) + '\nexec ' + shlex.quote(pi) + ' --offline --models ' + shlex.quote('fixture/*') + ' --no-session --no-extensions --no-mcp --no-skills --no-prompt-templates --no-context-files --no-approve\n'); launcher.chmod(0o700)
    if sdk_dialogs:
        fixture=root/'dialog-fixture.ts'
        result=root/'dialog-result.json'
        fixture.write_text("import {writeFileSync} from 'node:fs'; export default function(pi) { pi.registerCommand('fixture-dialog',{description:'Offline dialog acceptance fixture',handler:async(args,ctx)=>{const destination=await ctx.ui.select('Unseen destination',['lunar-base','ocean']);const permission=await ctx.ui.confirm('Unseen permission','Approve this offline fixture?');const note=await ctx.ui.input('Unseen question','Write a note');writeFileSync("+json.dumps(str(result))+",JSON.stringify({destination,permission,note,pid:process.pid}));}});}")
        command=launcher.read_text().replace('exec ', 'export AGENTMUX_BRIDGE_DIR='+shlex.quote(str(root/'bridges'))+'\nexec ',1)
        command=command.rstrip()+' -e '+shlex.quote(str(repo/'integrations/pi/agentmux.ts'))+' -e '+shlex.quote(str(fixture))+'\n'
        launcher.write_text(command)
    pane = run('new-session', '-d', '-P', '-F', '#{pane_id}', '-s', 'manual-pi', '-x', '47' if narrow else '120', '-y', '23' if narrow else '45', '-c', str(root), str(launcher))
    config = root / 'config.json'; config.write_text(json.dumps({'revision': 0, 'roots': [str(root)], 'default_directory': str(root), 'agents': {'codex': 'codex', 'claude': 'claude', 'pi': pi}}))
    token = secrets.token_hex(32)
    env = dict(os.environ, AGENTMUX_API_PORT=str(port), AGENTMUX_TOKEN=token, AGENTMUX_CONFIG=str(config), AGENTMUX_TMUX=str(wrapper), AGENTMUX_STATE=str(root / 'state'), AGENTMUX_DISCOVERY=str(root / 'service.json'), AGENTMUX_BRIDGE_DIR=str(root / 'bridges'), AGENTMUX_SSH_DISABLED='1', PI_CODING_AGENT_DIR=str(home))
    output = (root / 'daemon.log').open('w')
    daemon = subprocess.Popen([str(repo / 'target/debug/agentmuxd')], env=env, stdout=output, stderr=output)
    def request(path, value=None):
        req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=None if value is None else json.dumps(value).encode(), headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=15) as response: return json.load(response)
    def wait(predicate):
        for _ in range(100):
            try:
                value = predicate()
                if value: return value
            except urllib.error.URLError: pass
            time.sleep(.05)
        raise AssertionError('Pi state timeout; cursor=' + run('display-message', '-p', '-t', pane, '#{cursor_x},#{cursor_y},#{cursor_flag}') + '; screen=' + repr(run('capture-pane', '-p', '-e', '-t', pane)))
    try:
        session = wait(lambda: next((s for s in request('/v1/sessions') if s['id'] == pane), None))
        pid = session['agent_pid']; base = '/v1/sessions/' + urllib.parse.quote(pane, safe='')
        def snapshot(): return request(base + '/chat')
        def action(name, **values): return request(base + '/actions', {'action': name, 'agent_pid': pid, **values})
        wait(lambda: snapshot()['capabilities']['message'])
        if sdk_dialogs:
            action('model',model='model-c',provider='fixture')
            run('send-keys','-t',pane,'-l','/fixture-dialog');run('send-keys','-t',pane,'Enter')
            for kind,answer in [('select','ocean'),('confirm',''),('input','来自手机的答案')]:
                card=wait(lambda: next((a for a in snapshot()['approvals'] if a['kind']==kind),None))
                action('approval',request_id=card['id'],approved=True,text=answer)
            wait(lambda: result.exists())
            actual=json.loads(result.read_text())
            assert actual=={'destination':'ocean','permission':True,'note':'来自手机的答案','pid':pid},actual
            assert next(s for s in request('/v1/sessions') if s['id']==pane)['agent_pid']==pid
            print('PASS: real installed Pi SDK: model change and arbitrary select/confirm/input through Rust API; original Mac dialogs dismissed, continuations resumed once, original PID preserved; no model prompt')
        else:
            action('message', text='/model', request_id='real-pi-model')
            menu = wait(lambda: snapshot().get('interaction'))
            if narrow:
                assert menu['searchable'], menu
                # Search editing no longer clears the original input via C-a/C-k.
                run('send-keys', '-t', pane, '-l', '--', 'model-c')
                menu=wait(lambda: (m if m and len(m['options'])==1 and 'model-c' in m['options'][0]['label'] else None) if (m:=snapshot().get('interaction')) else None)
            else: assert len(menu['options']) >= 3, menu
            target = next(choice['id'] for choice in menu['options'] if 'model-c' in choice['label'])
            already_selected=next(c for c in menu['options'] if c['id']==target)['selected']
            action('menu_select', menu_id=menu['id'], choice=target)
            updated = wait(lambda: (value if value and (already_selected or value['id'] != menu['id']) else None) if (value := snapshot().get('interaction')) else None)
            assert next(choice for choice in updated['options'] if choice['selected'])['id'] == target
            action('menu_confirm', menu_id=updated['id'])
            wait(lambda: snapshot()['capabilities']['message'])
            wait(lambda: 'model-c' in run('capture-pane', '-p', '-t', pane))
            assert next(s for s in request('/v1/sessions') if s['id'] == pane)['agent_pid'] == pid
            os.kill(pid, 0)
            assert request('/v1/managed') == []
            print('PASS: actual installed Pi TUI started before AgentMux: empty editor, /model, unnumbered menu, navigate/confirm, model changed, original PID preserved; offline, no model prompt')
    finally:
        daemon.terminate()
        try: daemon.wait(timeout=5)
        except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()
        subprocess.run([tmux, '-L', server, 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        output.close()
