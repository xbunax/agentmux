#!/usr/bin/env python3
"""Acceptance test: all three Agent processes predate AgentMux and stay unchanged."""
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

repo=Path(__file__).resolve().parent.parent
subprocess.run(['cargo','build'],cwd=repo,check=True)
tmux=shutil.which('tmux')
assert tmux
with socket.socket() as probe:
    probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='agentmux-manual-') as temporary:
    root=Path(temporary).resolve();project=root/'project';project.mkdir()
    server='agentmux-manual-'+secrets.token_hex(6)
    wrapper=root/'tmux';wrapper.write_text(f'#!/bin/sh\nexec "{tmux}" -f /dev/null -L "{server}" "$@"\n');wrapper.chmod(0o700)
    def run(*args): return subprocess.check_output([str(wrapper),*args],text=True).strip()
    agents={};panes={};events={}
    for provider in ['codex','claude','pi']:
        agents[provider]=str(root/provider);events[provider]=root/(provider+'.jsonl')
        Path(agents[provider]).write_text(f'#!/bin/sh\n"{sys.executable}" "{repo / "scripts/fake-tui-agent.py"}" {provider} "{events[provider]}"\n');Path(agents[provider]).chmod(0o700)
        # Manual tmux launch BEFORE the daemon exists. No POST /v1/managed or /v1/sessions.
        panes[provider]=run('new-session','-d','-P','-F','#{pane_id}','-s',provider,'-x','110','-y','35','-c',str(project),'/bin/sh',agents[provider])
    token=secrets.token_hex(32);config=root/'config.json'
    config.write_text(json.dumps({'revision':0,'roots':[str(project)],'default_directory':str(project),'agents':agents}))
    env=dict(os.environ,AGENTMUX_API_PORT=str(port),AGENTMUX_TOKEN=token,AGENTMUX_CONFIG=str(config),AGENTMUX_TMUX=str(wrapper),AGENTMUX_STATE=str(root/'state'),AGENTMUX_DISCOVERY=str(root/'discovery.json'),AGENTMUX_BRIDGE_DIR=str(root/'bridges'),AGENTMUX_SSH_DISABLED='1',CODEX_HOME=str(root/'codex-home'),CLAUDE_CONFIG_DIR=str(root/'claude-home'),PI_CODING_AGENT_DIR=str(root/'pi-home'))
    log=(root/'service.log').open('w+')
    daemon=subprocess.Popen([str(repo/'target/debug/agentmuxd')],env=env,stdout=log,stderr=log)
    def request(path,value=None):
        req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,data=None if value is None else json.dumps(value).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req,timeout=15) as response:return response.status,json.load(response)
        except urllib.error.HTTPError as error:return error.code,error.read().decode()
    def records(provider):
        return [json.loads(line) for line in events[provider].read_text().splitlines()] if events[provider].exists() else []
    def wait(predicate):
        for _ in range(100):
            value=predicate()
            if value:return value
            time.sleep(.03)
        raise AssertionError('Timed out waiting for fixture state')
    try:
        for _ in range(100):
            try:
                if request('/v1/settings')[0]==200:break
            except urllib.error.URLError:time.sleep(.05)
        assert request('/v1/managed')[1]==[]
        listed=wait(lambda:{s['command']:s for s in request('/v1/sessions')[1]} if len(request('/v1/sessions')[1])==3 else None)
        for provider in ['codex','claude','pi']:
            session=listed[provider];pid=session['agent_pid'];pane=panes[provider]
            assert session['id']==pane
            base='/v1/sessions/'+urllib.parse.quote(pane,safe='')
            def snapshot():
                status,value=request(base+'/chat');assert status==200,value;return value
            def action(name,**values):return request(base+'/actions',{'action':name,'agent_pid':pid,**values})
            state=wait(lambda:snapshot() if snapshot()['capabilities']['message'] else None)
            assert state['conversation_id'] is None and state['messages']==[]
            assert any(c['name']=='model' for c in state['commands'])
            message={'text':'hello-'+provider,'request_id':'once-'+provider}
            assert action('message',**message)[0]==200
            assert action('message',**message)[0]==200
            wait(lambda:any(r.get('text')==message['text'] for r in records(provider)))
            assert sum(r.get('text')==message['text'] for r in records(provider))==1
            run('send-keys','-t',pane,'-l','Mac draft')
            wait(lambda:not snapshot()['capabilities']['message'])
            assert action('message',text='must not overwrite',request_id='draft')[0]==409
            run('send-keys','-t',pane,'C-u')
            wait(lambda:snapshot()['capabilities']['message'])
            assert action('message',text='/model',request_id='model-menu')[0]==200
            menu=wait(lambda:snapshot().get('interaction'))
            assert len(menu['options'])==3
            assert action('menu_select',menu_id=menu['id'],choice=2)[0]==200
            updated=wait(lambda:(value if value and value['id']!=menu['id'] else None) if (value:=snapshot().get('interaction')) else None)
            assert updated['options'][2]['selected']
            assert not any(r['kind']=='model' for r in records(provider))
            assert action('menu_confirm',menu_id=menu['id'])[0]==409
            assert action('menu_confirm',menu_id=updated['id'])[0]==200
            wait(lambda:any(r['kind']=='model' and r['value']=='Model C' for r in records(provider)))
            wait(lambda:snapshot()['capabilities']['message'])
            assert action('message',text='/ask',request_id='approval-menu')[0]==200
            menu=wait(lambda:snapshot().get('interaction'))
            assert not events[provider].with_suffix('.approved').exists()
            assert action('menu_confirm',menu_id=menu['id'])[0]==200
            wait(lambda:events[provider].with_suffix('.approved').exists())
            wait(lambda:snapshot()['capabilities']['message'])
            assert action('message',text='work',request_id='working')[0]==200
            wait(lambda:not snapshot()['capabilities']['message'])
            assert action('abort')[0]==200
            wait(lambda:any(r['kind']=='abort' for r in records(provider)))
            current=next(s for s in request('/v1/sessions')[1] if s['id']==pane)
            assert current['agent_pid']==pid
            actual_pids={record['pid'] for record in records(provider)}
            assert len(actual_pids)==1, 'The Agent child process must also remain unchanged'
            os.kill(next(iter(actual_pids)),0)
            print(f'PASS: manually started {provider}: placeholder, send/reply delivery, slash menu, model choice, stale-menu rejection, explicit approval, cancellation and original PID preserved',flush=True)
        assert request('/v1/managed')[1]==[]
    finally:
        daemon.terminate()
        try:daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:daemon.kill();daemon.wait()
        subprocess.run([tmux,'-L',server,'kill-server'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        log.close()
