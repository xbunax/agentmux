#!/usr/bin/env python3
"""Upload, confinement and native image routing; isolated service and fake providers."""
import base64
import json
import os
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
subprocess.run(['cargo', 'build', '--offline'], cwd=repo, check=True)
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='agentmux-attachment-test-') as temporary:
    root = Path(temporary).resolve()
    agents = {}
    for provider in ['codex', 'claude', 'pi']:
        executable = root / provider
        executable.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(repo / 'scripts/fake-agent.py')) + ' "$@"\n')
        executable.chmod(0o700); agents[provider] = str(executable)
    config = root / 'config.json'
    config.write_text(json.dumps({'revision': 0, 'roots': [str(root)], 'default_directory': str(root), 'agents': agents}))
    token = secrets.token_hex(32)
    env = dict(os.environ, AGENTMUX_API_PORT=str(port), AGENTMUX_TOKEN=token, AGENTMUX_CONFIG=str(config), AGENTMUX_STATE=str(root / 'state'), AGENTMUX_DISCOVERY=str(root / 'discovery.json'), AGENTMUX_SSH_DISABLED='1', AGENTMUX_FIXTURE_LOG=str(root / 'native'))
    output = (root / 'daemon.log').open('w')
    daemon = subprocess.Popen([str(repo / 'target/debug/agentmuxd')], env=env, stdout=output, stderr=output)
    storage = None
    def request(path, value=None, data=None, method=None, authenticated=True):
        headers = {'Authorization': 'Bearer ' + token} if authenticated else {}
        if value is not None: data = json.dumps(value).encode(); headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                content = response.read()
                return response.status, json.loads(content) if response.headers.get_content_type() == 'application/json' else content
        except urllib.error.HTTPError as error: return error.code, error.read()
    def wait(predicate):
        for _ in range(100):
            try:
                result = predicate()
                if result: return result
            except urllib.error.URLError: pass
            time.sleep(.05)
        raise AssertionError('Fixture state timeout')
    def records(provider):
        path = root / ('native.' + provider)
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    try:
        wait(lambda: request('/v1/settings')[0] == 200)
        image_id, file_id = str(uuid.uuid4()), str(uuid.uuid4())
        image_bytes = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lS8AAAAASUVORK5CYII=')
        image_url = '/v1/attachments/' + image_id + '?name=' + urllib.parse.quote('截图 1.png')
        assert request(image_url, data=image_bytes, method='PUT', authenticated=False)[0] == 401
        status, image = request(image_url, data=image_bytes, method='PUT'); assert status == 200, image
        stored = Path(image['path']); storage = stored.parents[2]
        assert str(stored).startswith('/tmp/') and stored.read_bytes() == image_bytes
        assert image['mime_type'] == 'image/png' and stored.stat().st_mode & 0o777 == 0o600
        assert storage.stat().st_mode & 0o777 == 0o700
        assert request(image_url, data=image_bytes, method='PUT')[1] == image
        assert request(image_url, data=b'changed', method='PUT')[0] == 409
        assert request('/v1/attachments/' + image_id)[1] == image_bytes
        file_url = '/v1/attachments/' + file_id + '?name=notes.txt'
        status, file = request(file_url, data=b'attachment notes', method='PUT'); assert status == 200, file
        assert request('/v1/attachments/' + str(uuid.uuid4()) + '?name=..%2Foutside', data=b'x', method='PUT')[0] == 400
        assert request('/v1/attachments/' + str(uuid.uuid4()) + '?name=large', data=b'x' * (8 * 1024 * 1024 + 1), method='PUT')[0] == 413
        assert request('/v1/attachments/' + str(uuid.uuid4()))[0] == 404
        for provider in ['codex', 'claude', 'pi']:
            status, session = request('/v1/managed', {'agent': provider, 'directory': str(root)}); assert status == 200, session
            endpoint = '/v1/managed/' + session['id']
            value = {'action': 'message', 'text': 'Review the attached image and notes', 'request_id': provider + '-once', 'attachments': [image_id, file_id]}
            assert request(endpoint + '/actions', dict(value, attachments=[str(uuid.uuid4())]))[0] == 404
            assert request(endpoint + '/actions', dict(value, text='/model'))[0] == 400
            assert request(endpoint + '/actions', value)[0] == 200
            assert request(endpoint + '/actions', value)[0] == 200
            def native_messages():
                return [record for record in records(provider) if record.get('method') == 'turn/start' or record.get('type') in ['user', 'prompt']]
            delivered = wait(lambda: native_messages()); assert len(delivered) == 1
            record = delivered[0]
            if provider == 'codex':
                content = record['params']['input']; assert content[1] == {'type': 'localImage', 'path': image['path']}
                text = content[0]['text']
            elif provider == 'claude':
                content = record['message']['content']; assert base64.b64decode(content[1]['source']['data']) == image_bytes
                assert content[1]['source']['media_type'] == 'image/png'; text = content[0]['text']
            else:
                assert base64.b64decode(record['images'][0]['data']) == image_bytes
                assert record['images'][0]['mimeType'] == 'image/png'; text = record['message']
            assert image['path'] in text and file['path'] in text
            assert 'Review the attached image and notes' in text
            wait(lambda: not request(endpoint)[1]['busy'])
            print(f'PASS: {provider}: /tmp file receipts, original caption/file references, native image input and one-time delivery', flush=True)
        stored.write_bytes(b'x' * len(image_bytes))
        assert request('/v1/attachments/' + image_id)[0] == 409
        print('PASS: authenticated upload/download, Unicode names, MIME sniffing, private /tmp storage, upload idempotency, conflict/traversal/oversize/unknown-ID rejection and content integrity', flush=True)
    finally:
        daemon.terminate()
        try: daemon.wait(timeout=5)
        except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()
        output.close()
        if storage and storage.name.startswith('agentmux-uploads-'): shutil.rmtree(storage)
