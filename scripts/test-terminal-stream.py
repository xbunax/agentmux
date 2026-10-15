#!/usr/bin/env python3
"""Exercise the real tmux stream on an isolated server. No agents/model calls."""
import base64
import json
import hashlib
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
    second_token = secrets.token_hex(32)
    (root/'state').mkdir()
    (root/'state/devices.json').write_text(json.dumps([{'id':'test-second-phone','name':'Isolated second phone','hash':hashlib.sha256(second_token.encode()).hexdigest(),'created':int(time.time())}]))
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
    def open_target(auth=token, target_pane=None):
        status, data = req('/v1/terminal/panes/'+urllib.parse.quote(target_pane or pane,safe='')+'/open','POST',{'generic':True},auth)
        assert status == 200, (status,data)
        return json.loads(data)
    def stream(target, auth=token):
        generation = target['generation']
        response = urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/v1/terminal/streams/{generation}',headers={'Authorization':'Bearer '+auth}),timeout=10)
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
    def write(target, sequence, auth=token, **kwargs):
        return req('/v1/terminal/streams/'+target['generation']+'/input','POST',dict(sequence=sequence,request_id=str(uuid.uuid4()),**kwargs),auth)
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
        # Phone resize uses the live generation, resets the screen, and restores on disable/close.
        def next_event(events, kind):
            while True:
                event = events.get(timeout=12)
                if event['type'] == kind: return event
                assert event['type'] not in ['closed', 'eof', 'read-error'], event
        def dimensions(): return tm('display-message','-p','-t',pane,'#{pane_width}x#{pane_height}')
        original_size = dimensions()
        original_policy = tm('show-options','-w','-v','-t',pane,'window-size')
        fresh=open_target(); _, resize_events, _=stream(fresh)
        assert fresh['capabilities']['resize'] is True
        assert write(fresh,1,kind='resize',enabled=True,cols=0,rows=18)[0]==400
        assert write(fresh,1,kind='resize',enabled=True,cols=1001,rows=18)[0]==400
        assert write(fresh,1,kind='resize',enabled=True,cols=48,rows=18)[0]==200
        event=next_event(resize_events,'resized')
        assert (event['cols'],event['rows'])==(48,18), event
        assert dimensions()=='48x18'
        # Another authenticated phone may view but cannot own this window's dimensions.
        assert write(fresh,2,auth=second_token,kind='resize',enabled=True,cols=80,rows=24)[0]==403
        second=open_target(auth=second_token); _, second_events, _=stream(second,auth=second_token)
        assert write(second,1,auth=second_token,kind='resize',enabled=True,cols=80,rows=24)[0]==200
        rejected=next_event(second_events,'resize_rejected')
        assert '另一个连接' in rejected['reason'], rejected
        assert dimensions()=='48x18'
        assert req('/v1/terminal/streams/'+second['generation'],'DELETE',auth=second_token)[0]==204
        assert dimensions()=='48x18'
        assert b'UNKNOWN MENU'  in base64.b64decode(event['data'])
        assert write(fresh,1,kind='resize',enabled=True,cols=60,rows=20)[0]==409
        assert dimensions()=='48x18'
        assert write(fresh,2,kind='resize',enabled=True,cols=52,rows=16)[0]==200
        event=next_event(resize_events,'resized')
        assert (event['cols'],event['rows'])==(52,16)
        assert write(fresh,3,kind='resize',enabled=False)[0]==200
        next_event(resize_events,'resized')
        assert dimensions()==original_size
        assert tm('show-options','-w','-v','-t',pane,'window-size')==original_policy
        assert write(fresh,4,kind='resize',enabled=True,cols=40,rows=14)[0]==200
        next_event(resize_events,'resized')
        assert req('/v1/terminal/streams/'+fresh['generation'],'DELETE')[0]==204
        wait(lambda:dimensions()==original_size,'close did not restore original size')
        # Replacement must not let the old stream cleanup release the new generation's size.
        fresh=open_target(); _, resize_events, _=stream(fresh)
        assert write(fresh,1,kind='resize',enabled=True,cols=46,rows=15)[0]==200
        next_event(resize_events,'resized')
        replacement=open_target(); _, replacement_events, _=stream(replacement)
        assert dimensions()==original_size
        assert write(replacement,1,kind='resize',enabled=True,cols=50,rows=17)[0]==200
        next_event(replacement_events,'resized')
        time.sleep(.8)
        assert dimensions()=='50x17'
        assert req('/v1/terminal/streams/'+replacement['generation'],'DELETE')[0]==204
        wait(lambda:dimensions()==original_size,'replacement close did not restore')
        # A Mac user's new size must never be overwritten by cleanup.
        fresh=open_target(); _, resize_events, _=stream(fresh)
        assert write(fresh,1,kind='resize',enabled=True,cols=44,rows=16)[0]==200
        next_event(resize_events,'resized')
        tm('resize-window','-t',pane,'-x','90','-y','29')
        next_event(resize_events,'closed')
        time.sleep(.2)
        assert dimensions()=='90x29'
        # Restore from the durable journal after daemon termination, without restarting the TUI.
        original_size=dimensions()
        fresh=open_target(); _, resize_events, _=stream(fresh)
        assert write(fresh,1,kind='resize',enabled=True,cols=45,rows=17)[0]==200
        next_event(resize_events,'resized')
        service.kill(); service.wait(timeout=5)
        assert dimensions()=='45x17'
        service=subprocess.Popen([str(repo/'target/debug/agentmuxd')],env=env,stdout=log,stderr=log)
        wait(started,'daemon failed to restart')
        wait(lambda:dimensions()==original_size,'startup recovery did not restore original size')
        # A phone viewport sizes the target pane, not the entire split window.
        # Match a common layout: agent at left, two stacked panes at right.
        other=tm('split-window','-h','-d','-t',pane,'-P','-F','#{pane_id}','/bin/sh')
        lower=tm('split-window','-v','-d','-t',other,'-P','-F','#{pane_id}','/bin/sh')
        layout=tm('display-message','-p','-t',pane,'#{window_layout}')
        fresh=open_target(); _, resize_events, _=stream(fresh)
        assert write(fresh,1,kind='resize',enabled=True,cols=70,rows=22)[0]==200
        event=next_event(resize_events,'resized')
        assert (event['cols'],event['rows'])==(70,22), event
        assert dimensions()=='70x22'
        assert write(fresh,2,kind='resize',enabled=True,cols=48,rows=12)[0]==200
        event=next_event(resize_events,'resized')
        assert (event['cols'],event['rows'])==(48,12), event
        assert dimensions()=='48x12'
        assert write(fresh,3,kind='resize',enabled=True,cols=90,rows=32)[0]==200
        event=next_event(resize_events,'resized')
        assert (event['cols'],event['rows'])==(90,32), event
        members=tm('list-panes','-t',pane,'-F','#{pane_id}').splitlines()
        assert set(members)=={pane,other,lower}
        assert req('/v1/terminal/streams/'+fresh['generation'],'DELETE')[0]==204
        wait(lambda:tm('display-message','-p','-t',pane,'#{window_layout}')==layout,'split layout not restored')
        # A nested bottom-right target must fit both axes, too.
        fresh=open_target(target_pane=lower); _, resize_events, _=stream(fresh)
        for sequence,(cols,rows) in enumerate([(48,12),(70,22)],1):
            assert write(fresh,sequence,kind='resize',enabled=True,cols=cols,rows=rows)[0]==200
            event=next_event(resize_events,'resized')
            assert (event['cols'],event['rows'])==(cols,rows), event
            assert tm('display-message','-p','-t',lower,'#{pane_width}x#{pane_height}')==f'{cols}x{rows}'
        assert req('/v1/terminal/streams/'+fresh['generation'],'DELETE')[0]==204
        wait(lambda:tm('display-message','-p','-t',pane,'#{window_layout}')==layout,'nested split layout not restored')
        tm('kill-pane','-t',lower)
        tm('kill-pane','-t',other)
        # Same pane ID reused by respawn must not inherit an input generation.
        fresh=open_target(); _, _, _=stream(fresh)
        tm('respawn-pane','-k','-t',pane,'/bin/sh')
        assert write(fresh,1,kind='key',key='Enter')[0]==409
        # A disconnected generation cannot be reopened or replayed.
        assert req('/v1/terminal/streams/'+fresh['generation'])[0]==409
        print('PASS: real tmux stream, Unicode, active screen, explicit keys, multiline gating, unchanged grid, generation/sequence checks, mode change, phone resize/snapshots, restoration, crash recovery, split panes and pane respawn.')
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
