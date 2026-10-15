#!/usr/bin/env python3
"""Exercise the iOS transport source against an isolated Rust daemon."""

import json
import os
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
binary = os.environ.get("AGENTMUX_BINARY", str(repo / "target/debug/agentmuxd"))
with tempfile.TemporaryDirectory(prefix="agentmux-swift-") as temporary:
    root = Path(temporary)
    config = root / "config.json"
    config.write_text(
        json.dumps(
            {
                "revision": 0,
                "roots": [str(root)],
                "default_directory": str(root),
                "agents": {"pi": "pi", "codex": "codex", "claude": "claude"},
            }
        )
    )
    env = dict(
        os.environ,
        AGENTMUX_CONFIG=str(config),
        AGENTMUX_STATE=str(root / "state"),
        AGENTMUX_DISCOVERY=str(root / "service.json"),
        AGENTMUX_SSH_BIND="127.0.0.1:9848",
    )
    env.pop("AGENTMUX_TOKEN", None)
    env.pop("AGENTMUX_SSH_DISABLED", None)
    daemon = subprocess.Popen(
        [binary], env=env, start_new_session=True
    )
    try:
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", 9848), timeout=0.1):
                    break
            except OSError:
                if daemon.poll() is not None:
                    raise RuntimeError("Daemon exited") from None
                time.sleep(0.1)
        subprocess.run(
            [binary, "pair", "127.0.0.1"],
            env=env,
            stdout=subprocess.DEVNULL,
            check=True,
        )
        env["AGENTMUX_PAIR_JSON"] = str(root / "state/pair.json")
        subprocess.run(
            [os.environ.get("AGENTMUX_SSH_PROBE", str(repo / "build/swift-probe/debug/SSHProbe"))],
            env=env,
            check=True,
            timeout=90,
        )
    finally:
        os.killpg(daemon.pid, signal.SIGTERM)
        daemon.wait(timeout=10)
