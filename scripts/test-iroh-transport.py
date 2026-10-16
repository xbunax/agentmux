#!/usr/bin/env python3
"""Swift official iroh SDK ↔ isolated Rust daemon and isolated tmux.

No public relay, model provider, user config, or existing tmux server is used.
"""
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

repo = Path(__file__).resolve().parent.parent
binary = repo / "target/debug/agentmuxd"
probe = Path(os.environ.get("AGENTMUX_SSH_PROBE", str(repo / "build/ssh-login-probe/debug/SSHProbe")))
with tempfile.TemporaryDirectory(prefix="agentmux-iroh-") as temporary:
    root = Path(temporary).resolve()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    tmux = shutil.which("tmux")
    assert tmux, "tmux is required"
    wrapper = root / "tmux"
    wrapper.write_text(f'#!/bin/sh\nexec "{tmux}" -f /dev/null -L "iroh-{secrets.token_hex(8)}" "$@"\n')
    wrapper.chmod(0o700)
    pane = subprocess.check_output([str(wrapper), "new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "probe", "cat"], text=True).strip()
    config = root / "config.json"
    config.write_text(json.dumps({"revision": 0, "roots": [str(root)], "default_directory": str(root), "agents": dict.fromkeys(["codex", "claude", "pi"], "unused"), "iroh": {"enabled": True, "relay_urls": []}}))
    token = secrets.token_hex(32)
    env = dict(os.environ, AGENTMUX_CONFIG=str(config), AGENTMUX_STATE=str(root / "state"), AGENTMUX_DISCOVERY=str(root / "service.json"), AGENTMUX_TOKEN=token, AGENTMUX_API_PORT=str(port), AGENTMUX_TMUX=str(wrapper), AGENTMUX_SSH_DISABLED="1")
    log = (root / "daemon.log").open("w+")
    daemon = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for attempt in range(100):
            try:
                request = urllib.request.Request(f"http://127.0.0.1:{port}/v1/settings", headers={"Authorization": "Bearer " + token})
                with opener.open(request, timeout=1) as response:
                    assert response.status == 200
                break
            except OSError:
                assert daemon.poll() is None, "Daemon exited"
                time.sleep(.1)
        else:
            raise AssertionError("Daemon did not start")
        subprocess.run([str(binary), "pair", "--transport", "iroh"], env=env, stdout=subprocess.DEVNULL, timeout=25, check=True)
        code = root / "state/pair-iroh.json"
        assert code.stat().st_mode & 0o777 == 0o600
        assert (root / "state/iroh.key").stat().st_mode & 0o777 == 0o600
        subprocess.run([str(probe)], env=dict(env, AGENTMUX_IROH_PAIR_JSON=str(code), AGENTMUX_IROH_PANE=pane), timeout=120, check=True)
        screen = subprocess.check_output([str(wrapper), "capture-pane", "-p", "-t", pane], text=True)
        assert "iroh-中文" in screen, "Unicode input did not reach tmux"
        credentials = json.loads((root / "state/devices.json").read_text())
        assert not credentials, "Revoked device persisted"
        original = json.loads(code.read_text())
        daemon.terminate(); daemon.wait(timeout=5)
        daemon = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        for attempt in range(100):
            try:
                request = urllib.request.Request(f"http://127.0.0.1:{port}/v1/iroh/status", headers={"Authorization": "Bearer " + token})
                with opener.open(request, timeout=1) as response:
                    assert json.load(response)["endpoint_id"] == original["endpoint_id"]
                break
            except OSError:
                assert daemon.poll() is None
                time.sleep(.1)
        else:
            raise AssertionError("Restart did not restore daemon identity")
        print("PASS: daemon identity survives restart")
    except BaseException:
        log.flush(); print((root / "daemon.log").read_text())
        raise
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill(); daemon.wait()
        subprocess.run([str(wrapper), "kill-server"], check=False)
        log.close()
