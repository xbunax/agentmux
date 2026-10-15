#!/usr/bin/env python3
"""One-time local configuration. Never overwrites existing configuration."""

import json
import os
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else os.getcwd()).resolve(strict=True)
if not root.is_dir():
    raise SystemExit("Project root must be an existing directory")
config = Path(os.environ.get("AGENTMUX_CONFIG", str(Path.home() / ".config/agentmux/agentmux.json")))
config.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
agents = {name: shutil.which(name) or name for name in ["codex", "claude", "pi"]}
with os.fdopen(os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
    json.dump(
        {
            "revision": 0,
            "roots": [str(root)],
            "default_directory": str(root),
            "agents": agents,
        },
        file,
        indent=2,
    )
    file.write("\n")
config.chmod(0o600)
print(f"Created {config}: authorized root {root}")
print("Start agentmuxd, then run agentmuxd pair in a second terminal.")
