#!/usr/bin/env python3
"""Test the iOS transport through an independent SSH server, without QR or port 9848.

Requires Paramiko and an SSHProbe built with the current transport source.
"""

import json
from contextlib import suppress
import logging
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

import paramiko

logging.getLogger("paramiko").setLevel(logging.CRITICAL)
repo = Path(__file__).resolve().parent.parent
with socket.socket() as api_probe:
    api_probe.bind(("127.0.0.1", 0))
    api_port = api_probe.getsockname()[1]
if os.environ.get("AGENTMUX_SSH_TRACE"):
    paramiko.util.log_to_file(str(repo / "build/ssh-login-server.log"), level=logging.DEBUG)
    logging.getLogger("paramiko").setLevel(logging.DEBUG)
binary = str(repo / "target/debug/agentmuxd")
probe = os.environ.get("AGENTMUX_SSH_PROBE", str(repo / "build/ssh-login-probe/debug/SSHProbe"))
events = []


def trace(message):
    events.append(message)
    if os.environ.get("AGENTMUX_TEST_DEBUG"):
        print(message, flush=True)


def bridge(channel):
    try:
        trace("API bridge started")
        with socket.create_connection(("127.0.0.1", api_port), timeout=5) as remote:
            remote.settimeout(None)
            def responses():
                try:
                    while data := remote.recv(32768):
                        channel.sendall(data)
                except OSError:
                    pass
                finally:
                    channel.close()

            responder = threading.Thread(target=responses, daemon=True)
            responder.start()
            try:
                while data := channel.recv(32768):
                    trace(f"API bridge: {len(data)} request bytes")
                    remote.sendall(data)
            except OSError:
                pass
            finally:
                with suppress(OSError):
                    remote.shutdown(socket.SHUT_RDWR)
                responder.join(timeout=2)
    finally:
        channel.close()


class SSHServer(paramiko.ServerInterface):
    def __init__(self, env, public_key):
        self.env = env
        self.public_key = public_key
        self.forwarded = set()

    def get_allowed_auths(self, username):
        return "password,publickey"

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == "test-user" and password == "temporary-test-password" else paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == "test-user" and key == self.public_key else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        if destination != ("127.0.0.1", api_port):
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.forwarded.add(chanid)
        return paramiko.OPEN_SUCCEEDED

    def check_channel_exec_request(self, channel, command):
        def execute():
            result = subprocess.run(["/bin/sh", "-c", command.decode()], env=self.env, capture_output=True, timeout=15)
            if result.stdout:
                channel.sendall(result.stdout)
            if result.stderr:
                channel.sendall_stderr(result.stderr)
            channel.send_exit_status(result.returncode)
            channel.shutdown_write()
            channel.close()

        threading.Thread(target=execute, daemon=True).start()
        return True


with tempfile.TemporaryDirectory(prefix="agentmux-ssh-login-") as temporary:
    root = Path(temporary).resolve()
    env = os.environ.copy()
    env["AGENTMUX_CONFIG"] = str(root / "agentmux.json")
    env.pop("AGENTMUX_TOKEN", None)
    env.update(AGENTMUX_API_PORT=str(api_port), AGENTMUX_STATE=str(root / "state"), AGENTMUX_DISCOVERY=str(root / "service.json"), AGENTMUX_SSH_DISABLED="1")
    key_path = root / "id_ed25519"
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "test-passphrase", "-f", str(key_path)], check=True)
    private_key = paramiko.Ed25519Key.from_private_key_file(str(key_path), password="test-passphrase")
    # Ed25519 host keys match the daemon's preferred host-key algorithm.
    host_path = root / "host_ed25519"
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(host_path)], check=True)
    host_key = paramiko.Ed25519Key.from_private_key_file(str(host_path))
    wrong_key = paramiko.RSAKey.generate(2048)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    listener.settimeout(0.5)
    transports = []
    stopping = threading.Event()

    def serve_connection(connection):
        transport = paramiko.Transport(connection)
        transports.append(transport)
        transport.add_server_key(host_key)
        server = SSHServer(env, private_key)
        try:
            transport.start_server(server=server)
            while transport.is_active() and not stopping.is_set():
                channel = transport.accept(timeout=0.5)
                if channel is not None:
                    trace(f"Accepted channel {channel.chanid}; forwarding={channel.chanid in server.forwarded}")
                if channel is not None and channel.chanid in server.forwarded:
                    threading.Thread(target=bridge, args=(channel,), daemon=True).start()
        except (EOFError, paramiko.SSHException, OSError):
            pass
        finally:
            transport.close()

    def serve():
        while not stopping.is_set():
            try:
                connection, _ = listener.accept()
                threading.Thread(target=serve_connection, args=(connection,), daemon=True).start()
            except socket.timeout:
                continue
            except OSError:
                return

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    with tempfile.TemporaryFile() as log:
        daemon = subprocess.Popen([binary], cwd=root, env=env, stdout=log, stderr=log)
        try:
            for attempt in range(100):
                if daemon.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read().decode())
                if (root / "service.json").exists():
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("Daemon did not publish discovery information")
            assert stat.S_IMODE((root / "service.json").stat().st_mode) == 0o600
            assert (root / "agentmux.json").is_file()
            # The enrollment endpoint cannot be used by an unauthenticated local client.
            request = urllib.request.Request(f"http://127.0.0.1:{api_port}/v1/devices", data=b'{"name":"unauthorized"}', headers={"Content-Type": "application/json"})
            try:
                urllib.request.urlopen(request)
                raise AssertionError("Unauthenticated enrollment was accepted")
            except urllib.error.HTTPError as error:
                assert error.code == 403
            probe_env = dict(env, AGENTMUX_SSH_HOST="127.0.0.1", AGENTMUX_SSH_PORT=str(listener.getsockname()[1]), AGENTMUX_SSH_HOST_KEY=f"{host_key.get_name()} {host_key.get_base64()}", AGENTMUX_SSH_WRONG_KEY=f"{wrong_key.get_name()} {wrong_key.get_base64()}")
            subprocess.run([probe], env=dict(probe_env, AGENTMUX_SSH_PASSWORD="temporary-test-password"), check=True, timeout=90)
            subprocess.run([probe], env=dict(probe_env, AGENTMUX_SSH_PRIVATE_KEY=str(key_path), AGENTMUX_SSH_PASSPHRASE="test-passphrase"), check=True, timeout=90)
            subprocess.run([probe], env=dict(probe_env, AGENTMUX_SSH_PASSWORD="incorrect-password", AGENTMUX_SSH_EXPECT_FAILURE="1"), check=True, timeout=30)
            discovery = root / "service.json"
            discovery.rename(root / "hidden-service.json")
            try:
                subprocess.run([probe], env=dict(probe_env, AGENTMUX_SSH_PASSWORD="temporary-test-password", AGENTMUX_SSH_EXPECT_FAILURE="1"), check=True, timeout=30)
            finally:
                (root / "hidden-service.json").rename(discovery)
            assert json.loads((root / "state/devices.json").read_text()) == []
            print("PASS: password and encrypted Ed25519 login; first-launch config; private discovery; no QR or AgentMux SSH listener required")
        except Exception:
            for event in events[-35:]:
                print(event, flush=True)
            raise
        finally:
            stopping.set()
            listener.close()
            for transport in transports:
                transport.close()
            daemon.send_signal(signal.SIGINT)
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()
            thread.join(timeout=2)
