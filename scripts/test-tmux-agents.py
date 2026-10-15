#!/usr/bin/env python3
"""Real isolated tmux/process-tree tests; fake agents, no model requests."""
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
assert tmux
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    api_port = probe.getsockname()[1]
with tempfile.TemporaryDirectory(prefix="agentmux-discovery-") as temporary:
    root = Path(temporary).resolve()
    project = root / "project"
    outside = root / "outside"
    project.mkdir()
    outside.mkdir()
    socket_name = "agentmux-discovery-" + secrets.token_hex(8)
    wrapper = root / "tmux"
    wrapper.write_text(f'#!/bin/sh\nexec "{tmux}" -f /dev/null -L "{socket_name}" "$@"\n')
    wrapper.chmod(0o700)
    token = secrets.token_hex(32)
    agents = {}
    for provider, prompt in [("codex", "›"), ("claude", "❯"), ("pi", "")]:
        path = root / provider
        path.write_text(f'#!/bin/sh\nstty -echo\nprintf "\\033[2J\\033[H{prompt} "\nwhile IFS= read -r line; do printf "%s\\n" "$line" >> "{root / (provider + ".received")}"; printf "\\033[2J\\033[H{prompt} "; done\n')
        path.chmod(0o700)
        agents[provider] = str(path)
    # Load the actual Pi extension in a fake SDK host, then relay through the daemon.
    node = shutil.which("node")
    assert node, "Node.js 22.18+ is required for the Pi extension fixture"
    pi_host = root / "pi.mjs"
    pi_host.write_text("import extension from " + json.dumps((repo / "integrations/pi/agentmux.ts").as_uri()) + ";\n" + "const handlers = new Map(); let idle = true; const ctx = {cwd:" + json.dumps(str(project)) + ",model:{id:'fixture',provider:'test',name:'Test'},ui:{getEditorText:()=>'',notify(){}},sessionManager:{getBranch:()=>[{type:'message',id:'a',parentId:null,message:{role:'assistant',content:[{type:'text',text:'Pi native bridge'}]}}],getSessionId:()=> 'fixture'},modelRegistry:{getAvailable:()=>[{id:'fixture',provider:'test',name:'Test'}]},isIdle:()=>idle,hasPendingMessages:()=>false,abort:()=>{idle=true;handlers.get('agent_settled')?.({},ctx)}}; extension({on:(e,h)=>handlers.set(e,h),sendUserMessage:()=>{idle=false;handlers.get('agent_start')?.({},ctx)},setModel:async()=>true}); await handlers.get('session_start')({},ctx); process.on('SIGTERM',async()=>{await handlers.get('session_shutdown')({},ctx);process.exit()});")
    agents["pi"] = str(pi_host)
    config_path = root / "config.json"
    config_path.write_text(json.dumps({"revision": 0, "roots": [str(project)], "default_directory": str(project), "agents": agents}))
    codex_home = root / "codex-home"
    logs = codex_home / "sessions/2026/10/15"
    logs.mkdir(parents=True)
    transcript = logs / "rollout-fixture.jsonl"
    transcript.write_text(json.dumps({"type": "session_meta", "payload": {"id": "fixture", "cwd": str(outside)}}) + "\n" + json.dumps({"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "real structured record"}]}}) + "\n")
    env = dict(os.environ, AGENTMUX_TOKEN=token, AGENTMUX_API_PORT=str(api_port), AGENTMUX_CONFIG=str(config_path), AGENTMUX_TMUX=str(wrapper), AGENTMUX_STATE=str(root / "state"), AGENTMUX_DISCOVERY=str(root / "service.json"), AGENTMUX_SSH_DISABLED="1", CODEX_HOME=str(codex_home), CLAUDE_CONFIG_DIR=str(root / "claude-home"), PI_CODING_AGENT_DIR=str(root / "pi-home"), AGENTMUX_BRIDGE_DIR=str(root / "bridges"))
    log = (root / "service.log").open("w+")
    process = subprocess.Popen([str(repo / "target/debug/agentmuxd")], env=env, stdout=log, stderr=log)
    def run(*args):
        return subprocess.check_output([str(wrapper), *args], text=True, env=env).strip()
    def request(path, value=None):
        req = urllib.request.Request(f"http://127.0.0.1:{api_port}" + path, data=None if value is None else json.dumps(value).encode(), headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode()
    try:
        for _ in range(100):
            try:
                if request("/v1/settings")[0] == 200:
                    break
            except urllib.error.URLError:
                time.sleep(.05)
        else:
            raise AssertionError("Daemon did not start")
        ordinary = run("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "ordinary", "-n", "codex-claude-pi", "-c", str(project), "/bin/sh")
        codex = run("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "work", "-n", "renamed-window", "-c", str(outside), "/bin/sh", agents["codex"])
        claude = run("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", codex, "/bin/sh", agents["claude"])
        pi = run("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "other", "-n", "research", "-c", str(project), node, "--experimental-strip-types", agents["pi"])
        for _ in range(60):
            status, sessions = request("/v1/sessions")
            assert status == 200, sessions
            if {s["id"] for s in sessions} == {codex, claude, pi}:
                break
            time.sleep(.05)
        else:
            raise AssertionError(sessions)
        by_id = {s["id"]: s for s in sessions}
        assert ordinary not in by_id
        assert by_id[codex]["window_id"] == by_id[claude]["window_id"]
        assert by_id[codex]["command"] == "codex"
        assert by_id[claude]["command"] == "claude"
        assert by_id[pi]["command"] == "pi"
        assert by_id[codex]["directory"] == str(outside)  # all windows, not only file roots
        pi_path = "/v1/sessions/" + urllib.parse.quote(pi, safe="")
        for _ in range(100):
            pi_status, pi_snapshot = request(pi_path + "/chat")
            if pi_status == 200 and pi_snapshot.get("source") == "pi-extension":
                break
            time.sleep(.05)
        else:
            raise AssertionError(pi_snapshot)
        assert pi_snapshot["messages"][0]["text"] == "Pi native bridge"
        pi_message = {"action":"message", "agent_pid":by_id[pi]["agent_pid"], "text":"native input", "request_id":"pi-once"}
        assert request(pi_path + "/actions", pi_message)[0] == 200
        assert request(pi_path + "/actions", pi_message)[0] == 200
        assert request(pi_path + "/chat")[1]["busy"] is True
        assert request(pi_path + "/actions", {"action":"abort", "agent_pid":by_id[pi]["agent_pid"]})[0] == 200
        assert request(pi_path + "/actions", {"action":"model", "agent_pid":by_id[pi]["agent_pid"], "model":"fixture", "provider":"test"})[0] == 200
        path = "/v1/sessions/" + urllib.parse.quote(codex, safe="")
        status, snapshot = request(path + "/chat")
        assert status == 200, snapshot
        assert len(snapshot["conversations"]) == 1
        assert snapshot["messages"] == []  # never guess even a sole historical record
        pid = by_id[codex]["agent_pid"]
        action = {"action": "select_conversation", "agent_pid": pid, "conversation_id": snapshot["conversations"][0]["id"]}
        assert request(path + "/actions", action)[0] == 200
        status, snapshot = request(path + "/chat")
        assert snapshot["messages"][0]["text"] == "real structured record"
        for _ in range(50):
            if request(path + "/chat")[1]["capabilities"]["message"]:
                break
            time.sleep(.05)
        else:
            raise AssertionError(run("capture-pane", "-p", "-t", codex))
        message = {"action": "message", "agent_pid": pid, "request_id": "send-once", "text": "hello mobile"}
        assert request(path + "/actions", dict(message, agent_pid=pid+100000))[0] == 409
        assert request(path + "/actions", dict(message, text="bad\u001b[A"))[0] == 400
        assert request(path + "/actions", message)[0] == 200
        assert request(path + "/actions", message)[0] == 200
        for _ in range(50):
            received = root / "codex.received"
            if received.exists() and "hello mobile" in received.read_text():
                break
            time.sleep(.05)
        else:
            raise AssertionError("Message not forwarded")
        assert received.read_text().count("hello mobile") == 1
        assert request(path + "/actions", dict(message, text="different"))[0] == 409
        # Redraw a nonempty input line. A remote message must not overwrite this draft.
        run("display-message", "-p", "-t", codex, "#{pane_tty}")
        tty = run("display-message", "-p", "-t", codex, "#{pane_tty}")
        with open(tty, "w") as terminal:
            terminal.write("\033[2J\033[H› Mac draft")
        time.sleep(.1)
        assert request(path + "/actions", dict(message, request_id="draft-check"))[0] == 409
        run("kill-pane", "-t", codex)
        assert request(path + "/actions", dict(message, request_id="after-exit"))[0] == 404
        plain_path = "/v1/sessions/" + urllib.parse.quote(ordinary, safe="")
        assert request(plain_path + "/actions", message)[0] == 404
        assert request(plain_path + "/input", {"text": "echo unsafe"})[0] == 404
        print("PASS: all tmux sessions, renamed windows, multiple agent panes, ordinary-window filtering, outside-root discovery, structured history selection, PID binding, control rejection, delivery deduplication, Mac draft protection, exited-agent rejection")
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
        subprocess.run([tmux, "-L", socket_name, "kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log.close()
