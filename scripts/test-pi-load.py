#!/usr/bin/env python3
"""Load the real installed Pi extension SDK without sending any model prompt."""
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
pi = shutil.which("pi")
assert pi, "Install Pi first"
with tempfile.TemporaryDirectory(prefix="agentmux-pi-load-") as temporary:
    root = Path(temporary).resolve()
    env = dict(os.environ, PI_CODING_AGENT_DIR=str(root / "pi"), AGENTMUX_BRIDGE_DIR=str(root / "bridges"))
    with (root / "output.log").open("w+") as output:
        process = subprocess.Popen([pi, "--mode", "rpc", "-e", str(repo / "integrations/pi/agentmux.ts")], cwd=root, env=env, stdin=subprocess.PIPE, stdout=output, stderr=output, text=True)
        try:
            manifest_path = root / "bridges" / f"pi-{process.pid}.json"
            for _ in range(200):
                if manifest_path.exists():
                    break
                if process.poll() is not None:
                    raise AssertionError("Pi exited before loading the extension; inspect the installed SDK version")
                time.sleep(.05)
            else:
                raise AssertionError("Pi did not publish the extension bridge")
            manifest = json.loads(manifest_path.read_text())
            assert manifest_path.stat().st_mode & 0o777 == 0o600
            request = urllib.request.Request(f"http://127.0.0.1:{manifest['port']}/snapshot", headers={"Authorization": "Bearer " + manifest["token"]})
            with urllib.request.urlopen(request, timeout=5) as response:
                snapshot = json.load(response)
            assert snapshot["pid"] == process.pid
            assert snapshot["cwd"] == str(root)
            assert snapshot["busy"] is False
            assert isinstance(snapshot["entries"], list)
            assert isinstance(snapshot["models"], list)
            print("PASS: installed Pi loads the actual extension, exposes the same PID/session via the SDK, and publishes authenticated private discovery; no model prompt sent")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
