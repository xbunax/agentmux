#!/usr/bin/env python3
"""Real SSH + HTTP integration. --live invokes installed agents and a short model reply.
Run with build/test-venv/bin/python. Test credentials are never printed.
"""

import argparse
import base64
import http.client
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import paramiko

parser = argparse.ArgumentParser()
parser.add_argument("--live", action="store_true")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
binary = os.environ.get("AGENTMUX_BINARY", str(repo / "target/debug/agentmuxd"))
for port in [9847, 9848]:
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", port))


class Pinned(paramiko.MissingHostKeyPolicy):
    def __init__(self, expected):
        self.expected = expected

    def missing_host_key(self, client, hostname, key):
        if key.asbytes() != base64.b64decode(self.expected.split()[1]):
            raise paramiko.SSHException("Host key mismatch")


with tempfile.TemporaryDirectory(prefix="agentmux-ssh-test-") as temporary:
    root = Path(temporary)
    project = root / "project"
    project.mkdir()
    admin = secrets.token_hex(32)
    fixture = root / "agent"
    fixture.write_text(
        f'#!/bin/sh\nexec "{sys.executable}" "{repo / "scripts/fake-agent.py"}" "$@"\n'
    )
    fixture.chmod(0o700)
    executables = {
        name: shutil.which(name) if args.live else str(fixture)
        for name in ["pi", "codex", "claude"]
    }
    assert all(executables.values()), "Install all three agents for --live"
    config = root / "config.json"
    config.write_text(
        json.dumps(
            {
                "revision": 0,
                "roots": [str(project)],
                "default_directory": str(project),
                "agents": executables,
            }
        )
    )
    env = dict(
        os.environ,
        AGENTMUX_TOKEN=admin,
        AGENTMUX_CONFIG=str(config),
        AGENTMUX_STATE=str(root / "state"),
        AGENTMUX_DISCOVERY=str(root / "service.json"),
        AGENTMUX_SSH_BIND="127.0.0.1:9848",
    )
    env.pop("AGENTMUX_SSH_DISABLED", None)
    log = (root / "service.log").open("w+")
    process = subprocess.Popen(
        [binary],
        env=env,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    clients = []

    def decode(data: bytes) -> Any:
        try:
            return json.loads(data)
        except json.JSONDecodeError:
            return data.decode(errors="replace")

    def transport(client):
        result = client.get_transport()
        assert result is not None, "SSH connection closed"
        return result

    def local(path, value):
        connection = http.client.HTTPConnection("127.0.0.1", 9847, timeout=10)
        try:
            connection.request(
                "POST",
                path,
                body=json.dumps(value).encode(),
                headers={
                    "Authorization": "Bearer " + admin,
                    "Content-Type": "application/json",
                },
            )
            response = connection.getresponse()
            assert response.status == 200
            return decode(response.read())
        finally:
            connection.close()

    def connect(code, credential):
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(Pinned(code["host_key"]))
        client.connect(
            "127.0.0.1",
            port=9848,
            username="agentmux",
            password=credential,
            look_for_keys=False,
            allow_agent=False,
            timeout=10,
            auth_timeout=10,
        )
        clients.append(client)
        return client

    def request(client, token, path, method="GET", value=None) -> tuple[int, Any]:
        channel = transport(client).open_channel(
            "direct-tcpip", ("127.0.0.1", 9847), ("127.0.0.1", 0), timeout=10
        )
        channel.settimeout(35)
        connection = http.client.HTTPConnection("127.0.0.1", 9847, timeout=35)
        connection.sock = channel
        body = None if value is None else json.dumps(value).encode()
        connection.request(
            method,
            path,
            body=body,
            headers={
                "Authorization": "Bearer " + token,
                "Content-Type": "application/json",
                "Connection": "close",
            },
        )
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, decode(data) if data else None

    try:
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", 9848), timeout=0.1):
                    break
            except OSError:
                if process.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read()) from None
                time.sleep(0.1)
        code = local("/v1/pair/issue", {"host": "127.0.0.1"})
        assert code["expires"] > time.time()
        print("TEST: QR ticket issued, connecting SSH bootstrap", flush=True)
        bootstrap = connect(code, code["ticket"])
        print("TEST: bootstrap authenticated, exchanging ticket", flush=True)
        status, paired = request(
            bootstrap,
            "",
            "/v1/pair/complete",
            "POST",
            {"ticket": code["ticket"], "name": "Integration Test"},
        )
        assert status == 200, paired
        print("TEST: device credential issued", flush=True)
        token = paired["token"]
        bootstrap.close()
        try:
            connect(code, code["ticket"])
            raise AssertionError("One-time ticket was reusable")
        except paramiko.AuthenticationException:
            pass
        client = connect(code, token)
        assert request(client, token, "/v1/settings")[0] == 200
        assert (
            request(client, token, "/v1/pair/issue", "POST", {"host": "127.0.0.1"})[0]
            == 403
        )
        for kind, address in [("session", None), ("direct-tcpip", ("127.0.0.1", 22))]:
            try:
                transport(client).open_channel(
                    kind, address, ("127.0.0.1", 0), timeout=5
                )
                raise AssertionError("Forbidden channel accepted")
            except paramiko.ChannelException:
                pass
        print(
            "PASS: pinned SSH pairing, one-time ticket, reconnect, API auth, shell/forward restrictions",
            flush=True,
        )
        for agent in ["pi", "codex", "claude"]:
            status, created = request(
                client,
                token,
                "/v1/managed",
                "POST",
                {"agent": agent, "directory": str(project)},
            )
            assert status == 200, (agent, created)
            endpoint = "/v1/managed/" + created["id"]
            state = request(client, token, endpoint)[1]
            assert state["models"], (agent, "No advertised models", state.get("error"))
            selected = next(
                (m for m in state["models"] if m["id"] == state["model"]),
                state["models"][0],
            )
            status, result = request(
                client,
                token,
                endpoint + "/actions",
                "POST",
                {
                    "action": "model",
                    "model": selected["id"],
                    "provider": selected["provider"],
                },
            )
            assert status == 200, (agent, result)
            assert (
                request(
                    client,
                    token,
                    endpoint + "/actions",
                    "POST",
                    {"action": "model", "model": "not-advertised"},
                )[0]
                == 400
            )
            message_id = secrets.token_hex(16)
            action = {
                "action": "message",
                "text": "Reply with exactly AGENTMUX_OK. Do not call any tools.",
                "request_id": message_id,
            }
            status, result = request(
                client, token, endpoint + "/actions", "POST", action
            )
            assert status == 200, (agent, result)
            replies = []
            for _ in range(120):
                state = request(client, token, endpoint)[1]
                replies = [m for m in state["messages"] if m["role"] == "assistant"]
                if not state["busy"] and replies:
                    break
                time.sleep(1 if args.live else 0.05)
            assert any("AGENTMUX_OK" in m["text"] for m in replies), (
                agent,
                state.get("error"),
                replies,
            )
            assert (
                request(client, token, endpoint + "/actions", "POST", action)[0] == 200
            )
            assert (
                request(
                    client,
                    token,
                    endpoint + "/actions",
                    "POST",
                    dict(action, text="different text"),
                )[0]
                == 409
            )
            state = request(client, token, endpoint)[1]
            assert len([m for m in state["messages"] if m["role"] == "user"]) == 1
            if not args.live and agent in ["pi", "codex"]:
                assert (
                    request(
                        client,
                        token,
                        endpoint + "/actions",
                        "POST",
                        {"action": "command", "text": "compact"},
                    )[0]
                    == 200
                )
            print(
                f"PASS: {agent} native initialization, {len(state['models'])} models, {len(state['commands'])} commands, model selection, structured reply, deduplication",
                flush=True,
            )
        assert (
            request(client, token, "/v1/devices/" + paired["device_id"], "DELETE")[0]
            == 204
        )
        assert request(client, token, "/v1/settings")[0] == 401
        try:
            connect(code, token)
            raise AssertionError("Revoked device authenticated")
        except paramiko.AuthenticationException:
            pass
        print("PASS: device revocation on current and new connections", flush=True)
    finally:
        for client in clients:
            client.close()
        import signal

        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
        log.seek(0)
        service_output = log.read()
        if service_output.strip():
            print("Service diagnostics:\n" + service_output[-4000:], flush=True)
        log.close()
