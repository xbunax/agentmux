#!/usr/bin/env python3
"""Read-only readiness check of real existing panes using an isolated AgentMux daemon.

No input, managed sessions, plugin installation or service restart is performed.
Output contains provider/pane/readiness only, never conversation content.
"""
import json
import os
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='agentmux-readiness-') as temporary:
    root = Path(temporary).resolve()
    config = root / 'config.json'
    config.write_text(json.dumps({'revision': 0, 'roots': [str(repo)], 'default_directory': str(repo), 'agents': {'codex': 'codex', 'claude': 'claude', 'pi': 'pi'}}))
    token = secrets.token_hex(32)
    env = dict(os.environ, AGENTMUX_API_PORT=str(port), AGENTMUX_TOKEN=token, AGENTMUX_CONFIG=str(config), AGENTMUX_STATE=str(root / 'state'), AGENTMUX_DISCOVERY=str(root / 'service.json'), AGENTMUX_BRIDGE_DIR=str(root / 'bridges'), AGENTMUX_SSH_DISABLED='1')
    def read(path):
        request = urllib.request.Request(f'http://127.0.0.1:{port}{path}', headers={'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    with (root / 'daemon.log').open('w') as output:
        process = subprocess.Popen([str(repo / 'target/debug/agentmuxd')], env=env, stdout=output, stderr=output)
        try:
            for _ in range(100):
                try:
                    read('/v1/settings')
                    break
                except urllib.error.URLError:
                    time.sleep(.05)
            assert read('/v1/managed') == []
            sessions = read('/v1/sessions')
            for session in sessions:
                state = read('/v1/sessions/' + urllib.parse.quote(session['id'], safe='') + '/chat')
                print(json.dumps({'pane': session['id'], 'provider': session['command'], 'message_ready': state['capabilities']['message'], 'slash_commands': len(state['commands']), 'menu_visible': bool(state.get('interaction'))}), flush=True)
            print(f'Checked {len(sessions)} original Agent panes; GET requests only; no Agent input sent.')
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
