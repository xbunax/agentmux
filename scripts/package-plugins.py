#!/usr/bin/env python3
"""Build self-contained local plugin bundles; does not alter provider configuration."""
import json
import shutil
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
root = repo / 'dist/plugins'
root.mkdir(parents=True, exist_ok=True)
for provider in ['codex', 'claude']:
    destination = root / ('agentmux-' + provider)
    shutil.copytree(repo / 'integrations' / provider, destination, dirs_exist_ok=True, ignore=shutil.ignore_patterns('node_modules'))
    shutil.copytree(repo / 'integrations/shared', destination / 'shared', dirs_exist_ok=True)
pi = root / 'agentmux-pi'
pi.mkdir(exist_ok=True)
shutil.copy2(repo / 'integrations/pi/agentmux.ts', pi / 'agentmux.ts')
(pi / 'package.json').write_text(json.dumps({'name':'agentmux-pi', 'version':'0.4.0', 'type':'module', 'pi':{'extensions':['./agentmux.ts']}}, indent=2)+'\n')
claude = root / '.claude-plugin'
claude.mkdir(exist_ok=True)
(claude / 'marketplace.json').write_text(json.dumps({'name':'agentmux', 'owner':{'name':'AgentMux contributors'}, 'plugins':[{'name':'agentmux-claude','source':'./agentmux-claude','description':'SSH-backed mobile chat and permission relay for existing Claude Code sessions'}]},indent=2)+'\n')
codex = root / '.agents/plugins'
codex.mkdir(parents=True, exist_ok=True)
(codex / 'marketplace.json').write_text(json.dumps({'name':'agentmux','interface':{'displayName':'AgentMux'},'plugins':[{'name':'agentmux-codex','source':{'source':'local','path':'./agentmux-codex'},'policy':{'installation':'AVAILABLE','authentication':'ON_INSTALL'},'category':'Productivity'}]},indent=2)+'\n')
print('Plugin bundles: ' + str(root))
print('Install Claude dependencies: npm ci --ignore-scripts --prefix dist/plugins/agentmux-claude')
print('Bundles are ready for explicit installation; no global provider settings changed.')
