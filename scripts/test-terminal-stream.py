#!/usr/bin/env python3
"""Exercise the real tmux stream on an isolated server. No agents/model calls."""
import base64
import json
import os
import queue
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
subprocess.run(['cargo', 'build', '--quiet'], cwd=repo, check=True)
tmux = shutil.which('tmux')
assert tmux

def wait(predicate, message):
    for _ in range(100):
        if predicate(): return
        time.sleep(.05)
    raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix='agentmux-terminal-') as temporary:
    root = Path(temporary)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
    wrapper = root / 'tmux'
    sock = 'agentmux-terminal-' + secrets.token_hex(8)
    wrapper.write_text(f'#!/bin/sh\nexec "{tmux}" -f /dev/null -L "{sock}" "$@"\n')
    wrapper.chmod(0o700)
    def tm(*args): return subprocess.check_output([str(wrapper), *args], text=True).strip()
    fixture = root / 'unknown-tui.py'
    fixture.write_text('''import os, sys, tty
from pathlib import Path
tty.setraw(0)
log = Path(sys.argv[1])
os.write(1, b"\\x1b[?1049h\\x1b[?2004h\\x1b[?1h\\x1b[2J\\x1b[H\\x1b[32mUNKNOWN MENU\\x1b[0m\\r\\n")
os.write(1, "中文 · Mac draft: existing-text\\r\\n> parent / child / unfamiliar popup\\r\\n".encode())
while True:
    data = os.read(0, 4096)
    with log.open('ab') as out: out.write(data)
    if data == b'!': os.write(1, b'\\x1b[?2004l')
    os.write(1, b'\\x1b[5;1H\\x1b[36mreceived\\x1b[0m')
''')
    rawlog = root / 'input.bin'
    pane = tm('new-session', '-d', '-x', '100', '-y', '32', '-P', '-F', '#{pane_id}', '-s', 'isolated', 'python3', str(fixture), str(rawlog))
    config = root / 'config.json'
    config.write_text(json.dumps({'revision':0,'roots':[str(root)],'default_directory':str(root),'agents':dict.fromkeys(['codex','claude','pi'],'not-installed-agent')}))
    token = secrets.token_hex(32)
    env = dict(os.environ, AGENTMUX_CONFIG=str(config), AGENTMUX_TMUX=str(wrapper), AGENTMUX_TOKEN=token, AGENTMUX_API_PORT=str(port), AGENTMUX_STATE=str(root/'state'), AGENTMUX_DISCOVERY=str(root/'service.json'), AGENTMUX_SSH_DISABLED='1')
    log = (root / 'service.log').open('w+')
    service = subprocess.Popen([str(repo/'target/debug/agentmuxd')], env=env, stdout=log, stderr=log)
    responses = []
    def req(path, method='GET', value=None, auth=token):
        headers = {'Content-Type':'application/json'}
        if auth: headers['Authorization'] = 'Bearer ' + auth
        request = urllib.request.Request(f'http://127.0.0.1:{port}'+path, method=method, data=json.dumps(value).encode() if value is not None else None, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=10) as response: return response.status, response.read()
        except urllib.error.HTTPError as error: return error.code, error.read()
    def open_target():
        status, data = req('/v1/terminal/panes/'+urllib.parse.quote(pane,safe='')+'/open','POST',{'generic':True})
        assert status == 200, (status,data)
        return json.loads(data)
    def stream(target):
        generation = target['generation']
        response = urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/v1/terminal/streams/{generation}',headers={'Authorization':'Bearer '+token}),timeout=10)
        responses.append(response)
        events = queue.Queue()
        def read():
            try:
                for line in response: events.put(json.loads(line))
            except Exception as error: events.put({'type':'read-error','reason':str(error)})
            finally: events.put({'type':'eof'})
        threading.Thread(target=read,daemon=True).start()
        while True:
            first = events.get(timeout=12)
            if first['type'] == 'ping': continue
            assert first['type']=='ready', first
            return response, events, first
    def write(target, sequence, **kwargs):
        return req('/v1/terminal/streams/'+target['generation']+'/input','POST',dict(sequence=sequence,request_id=str(uuid.uuid4()),**kwargs))
    try:
        def started():
            try: return req('/v1/settings')[0]==200
            except urllib.error.URLError: return False
        wait(started,'daemon failed to start')
        wait(lambda:'UNKNOWN MENU' in tm('capture-pane','-p','-t',pane),'fixture failed')
        assert req('/v1/terminal/panes',auth=None)[0]==401
        assert json.loads(req('/v1/sessions')[1])==[]
        assert any(row['id']==pane for row in json.loads(req('/v1/terminal/panes')[1]))
        assert req('/v1/terminal/panes/'+urllib.parse.quote(pane,safe='')+'/open','POST',{})[0]==400
        target = open_target()
        assert write(target,1,kind='key',key='Enter')[0]==409
        before = tm('display-message','-p','-t',pane,'#{pane_width}x#{pane_height}')
        response, events, first = stream(target)
        screen = base64.b64decode(first['data'])
        assert b'UNKNOWN MENU' in screen and '中文'.encode() in screen and b'\x1b[' in screen, screen
        assert before == tm('display-message','-p','-t',pane,'#{pane_width}x#{pane_height}')=='100x32'
        assert (first['cols'],first['rows'])==(100,32)
        assert b'existing-text' in screen
        for sequence,key in enumerate(['Up','Down','Left','Right','Enter','Escape','Tab','BTab','BSpace'],1):
            status,data = write(target,sequence,kind='key',key=key); assert status==200,(status,data)
        assert write(target,9,kind='key',key='Enter')[0]==409
        assert write(target,11,kind='key',key='Enter')[0]==409
        assert write(target,10,kind='key',key='Enter; kill-server')[0]==400
        assert write(target,10,kind='text',text='\x1b[201~bad')[0]==400
        assert write(target,10,kind='text',text='中文🙂')[0]==200
        assert write(target,11,kind='paste',text='第一行\n第二行')[0]==400
        multi = target['capabilities']['multiline_paste']
        if multi:
            assert write(target,11,kind='paste',text='第一行\n第二行',confirm_multiline=True)[0]==200
            pasted = b'\x1b[200~'+'第一行\n第二行'.encode()+b'\x1b[201~'
        else:
            assert write(target,11,kind='paste',text='第一行\n第二行',confirm_multiline=True)[0]==400
            assert write(target,11,kind='paste',text='single-line')[0]==200
            pasted = b'single-line'
        expected = b'\x1bOA\x1bOB\x1bOD\x1bOC\r\x1b\t\x1b[Z\x7f'+'中文🙂'.encode()+pasted
        wait(lambda:rawlog.exists() and rawlog.read_bytes()==expected, 'literal keys / Unicode / paste bytes differ: '+repr(rawlog.read_bytes() if rawlog.exists() else b''))
        assert b'\x01' not in rawlog.read_bytes() and b'\x0b' not in rawlog.read_bytes()
        while True:
            event=events.get(timeout=10)
            if event['type']=='data':
                assert b'\x1b[5;1H' in base64.b64decode(event['data']); break
        # A new terminal mode is checked at write time, not from an old UI capability.
        assert write(target,12,kind='text',text='!')[0]==200
        wait(lambda:tm('display-message','-p','-t',pane,'#{?bracket_paste_flag,1,0}')=='0','paste mode did not change')
        assert write(target,13,kind='paste',text='no\nsubmit',confirm_multiline=True)[0]==400
        assert req('/v1/terminal/streams/'+target['generation'],'DELETE')[0]==204
        assert write(target,13,kind='key',key='Enter')[0]==409
        # Every reconnect gets a fresh generation; old IDs remain invalid.
        fresh=open_target(); response2, events2, _=stream(fresh)
        assert fresh['generation']!=target['generation']
        assert write(target,13,kind='key',key='Enter')[0]==409
        tm('resize-window','-t',pane,'-x','99','-y','31')
        while True:
            event=events2.get(timeout=10)
            if event['type'] in ['closed','eof']: break
        assert write(fresh,1,kind='key',key='Space')[0]==409
        # Same pane ID reused by respawn must not inherit an input generation.
        fresh=open_target(); _, _, _=stream(fresh)
        tm('respawn-pane','-k','-t',pane,'/bin/sh')
        assert write(fresh,1,kind='key',key='Enter')[0]==409
        # A disconnected generation cannot be reopened or replayed.
        assert req('/v1/terminal/streams/'+fresh['generation'])[0]==409
        print('PASS: real tmux stream, Unicode, active screen, explicit keys, multiline gating, unchanged grid, generation/sequence checks, mode change, resize and pane respawn.')
    finally:
        service.terminate()
        try: service.wait(timeout=5)
        except subprocess.TimeoutExpired: service.kill(); service.wait()
        subprocess.run([str(wrapper),'kill-server'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for response in responses:
            try: response.close()
            except Exception: pass
        log.seek(0)
        errors=log.read()
        if service.returncode not in [-15,0]: print(errors)
