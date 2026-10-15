#!/usr/bin/env python3
"""Isolated service/tmux integration tests. Does not invoke real agents."""

import json
import os
import secrets
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
subprocess.run(["cargo", "build"], cwd=repo, check=True)
tmux = shutil.which("tmux")
assert tmux, "tmux is required"
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 9847))
with tempfile.TemporaryDirectory(prefix="agentmux-test-") as temporary:
    root = Path(temporary).resolve()
    project = root / "project"
    project.mkdir()
    token = secrets.token_hex(32)
    socket_name = "agentmux-test-" + secrets.token_hex(8)
    wrapper = root / "tmux"
    wrapper.write_text(
        f'#!/bin/sh\nexec "{tmux}" -f /dev/null -L "{socket_name}" "$@"\n'
    )
    wrapper.chmod(0o700)
    agent = root / "fake-agent"
    agent.write_text(
        '#!/bin/sh\necho AGENT_READY\nwhile IFS= read -r line; do printf "received:%s\\n" "$line"; done\n'
    )
    agent.chmod(0o700)
    config = {
        "revision": 0,
        "roots": [str(project)],
        "default_directory": str(project),
        "agents": dict.fromkeys(["codex", "claude", "pi"], str(agent)),
    }
    config_path = root / "config.json"
    config_path.write_text(json.dumps(config))
    env = dict(
        os.environ,
        AGENTMUX_TOKEN=token,
        AGENTMUX_CONFIG=str(config_path),
        AGENTMUX_TMUX=str(wrapper),
        AGENTMUX_STATE=str(root / "state"),
        AGENTMUX_SSH_DISABLED="1",
    )
    log = (root / "service.log").open("w+")
    process = subprocess.Popen(
        [str(repo / "target/debug/agentmuxd")], env=env, stdout=log, stderr=log
    )

    def request(path, method="GET", value=None, authenticated=True):
        data = (
            value
            if isinstance(value, bytes)
            else None
            if value is None
            else json.dumps(value).encode()
        )
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(
            "http://127.0.0.1:9847" + path, data=data, method=method, headers=headers
        )
        try:
            # URL is constructed above with a fixed HTTP loopback origin, never user input.
            with urllib.request.urlopen(req, timeout=15) as response:  # noqa: S310
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def file_path(path):
        return "/v1/file?" + urllib.parse.urlencode({"path": str(path)})

    try:
        for _ in range(100):
            if process.poll() is not None:
                log.seek(0)
                raise RuntimeError(log.read())
            try:
                if request("/v1/settings")[0] == 200:
                    break
            except urllib.error.URLError:
                time.sleep(0.05)
        else:
            raise AssertionError("Service startup timed out")
        assert request("/v1/settings", authenticated=False)[0] == 401
        assert json.loads(request("/v1/settings")[1]) == config
        changed = dict(config, default_directory=str(root))
        assert request("/v1/settings", "PUT", changed)[0] == 403
        assert request("/v1/settings", "PUT", config)[0] == 200
        assert request("/v1/settings", "PUT", config)[0] == 409
        assert json.loads(config_path.read_text())["revision"] == 1
        status, body = request(
            "/v1/sessions", "POST", {"agent": "codex", "directory": str(project)}
        )
        assert status == 200, body
        pane = json.loads(body)["id"]
        encoded_pane = urllib.parse.quote(pane, safe="")
        session_path = "/v1/sessions/" + encoded_pane
        assert any(s["id"] == pane for s in json.loads(request("/v1/sessions")[1]))
        assert (
            request(session_path + "/input", "POST", {"text": "hello-agentmux"})[0]
            == 204
        )
        for _ in range(50):
            if b"received:hello-agentmux" in request(session_path + "/output")[1]:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("Agent did not receive input")
        assert (
            request(
                "/v1/sessions", "POST", {"agent": "unknown", "directory": str(project)}
            )[0]
            == 400
        )
        assert (
            request("/v1/sessions", "POST", {"agent": "pi", "directory": str(root)})[0]
            == 403
        )
        target = project / "hello.txt"
        assert request(file_path(target), "PUT", b"file-transfer-test")[0] == 201
        assert request(file_path(target))[1] == b"file-transfer-test"
        assert request(file_path(target), "PUT", b"overwrite")[0] == 409
        outside = root / "secret.txt"
        outside.write_text("secret")
        (project / "escape").symlink_to(outside)
        assert request(file_path(project / "escape"))[0] != 200
        assert request(file_path(outside))[0] == 403
        assert (
            request(
                file_path(project / "large.bin"), "PUT", b"x" * (8 * 1024 * 1024 + 1)
            )[0]
            == 413
        )
        listing = "/v1/files?" + urllib.parse.urlencode({"path": str(project)})
        assert any(e["name"] == "hello.txt" for e in json.loads(request(listing)[1]))
        print(
            "PASS: auth, config persistence/conflicts, tmux create/list/input/output, directory boundaries, upload/download/conflicts/size/symlink checks"
        )
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        subprocess.run(
            [tmux, "-L", socket_name, "kill-server"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log.close()
