#!/usr/bin/env python3
"""Live loopback HTTP regression checks without a tmux server or model calls."""
import json
import os
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
subprocess.run(['cargo', 'build', '--quiet'], cwd=repo, check=True)
with tempfile.TemporaryDirectory(prefix='agentmux-api-') as temporary:
    root = Path(temporary)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
    config = root / 'config.json'
    config.write_text(json.dumps({'revision': 0, 'roots': [str(root)], 'default_directory': str(root), 'agents': dict.fromkeys(['codex', 'claude', 'pi'], 'not-installed-agent')}))
    token = secrets.token_hex(32)
    env = dict(os.environ, AGENTMUX_CONFIG=str(config), AGENTMUX_TOKEN=token,
               AGENTMUX_API_PORT=str(port), AGENTMUX_STATE=str(root / 'state'),
               AGENTMUX_DISCOVERY=str(root / 'service.json'), AGENTMUX_SSH_DISABLED='1',
               AGENTMUX_TMUX=str(root / 'intentionally-no-tmux'))
    with (root / 'service.log').open('w+') as log:
        service = subprocess.Popen([str(repo / 'target/debug/agentmuxd')], env=env, stdout=log, stderr=log)
        def request(path, method='GET', body=None, auth=token):
            headers = {'Content-Type': 'application/json'}
            if auth: headers['Authorization'] = 'Bearer ' + auth
            req = urllib.request.Request(f'http://127.0.0.1:{port}' + path, method=method,
                                         data=json.dumps(body).encode() if body is not None else None, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=5) as response: return response.status
            except urllib.error.HTTPError as error: return error.code
        try:
            for _ in range(100):
                if service.poll() is not None:
                    log.seek(0); raise AssertionError(log.read())
                try:
                    if request('/v1/settings') == 200: break
                except urllib.error.URLError: pass
                time.sleep(.05)
            else: raise AssertionError('daemon did not start')
            routes = [('/v1/terminal/panes', 'GET', None),
                      ('/v1/terminal/panes/%251/open', 'POST', {'generic': True}),
                      ('/v1/terminal/streams/missing', 'GET', None),
                      ('/v1/terminal/streams/missing', 'DELETE', None),
                      ('/v1/terminal/streams/missing/input', 'POST', {'sequence': 1, 'request_id': 'unknown', 'kind': 'key', 'key': 'Enter'}),
                      ('/v1/sessions/%251/input', 'POST', {'text': 'must not reach tmux'}),
                      ('/v1/sessions/%251/interrupt', 'POST', {})]
            for path, method, body in routes:
                for credential in [None, 'wrong-token']:
                    assert request(path, method, body, credential) == 401, path
            for path, method, body in routes[-2:]:
                assert request(path, method, body) == 410
            assert request('/v1/terminal/panes/%251%3Bkill-server/open', 'POST', {'generic': True}) == 400
            for path, method, body in routes[2:5]:
                assert request(path, method, body) == 409
            print('PASS: live HTTP authentication on all terminal routes, retired write endpoints, invalid pane IDs and missing generations; no tmux or model invoked.')
        finally:
            service.terminate()
            try: service.wait(timeout=5)
            except subprocess.TimeoutExpired: service.kill(); service.wait()
