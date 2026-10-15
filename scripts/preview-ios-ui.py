#!/usr/bin/env python3
"""Build and capture the actual SwiftUI app in an isolated iOS simulator.

Fixture mode never connects to a user daemon or sends model requests. Requires
macOS, Xcode, XcodeGen and an already installed iOS simulator runtime.
"""
import argparse
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--build-only', action='store_true')
parser.add_argument('--screen', choices=['sessions', 'chat', 'menu', 'commands', 'attachments', 'text', 'micro', 'glide', 'keyboard'], default='text')
parser.add_argument('--light', action='store_true')
parser.add_argument('--output', default='build/ui-preview.png')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent

def run(*command):
    return subprocess.check_output(command, text=True).strip()

runtimes = json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
runtime = next((r['identifier'] for r in reversed(runtimes) if r.get('isAvailable') and r['name'].startswith('iOS')), None)
if not runtime:
    raise SystemExit('Install an iOS simulator runtime in Xcode before running this preview.')
types = json.loads(run('xcrun', 'simctl', 'list', 'devicetypes', '-j'))['devicetypes']
device = next(t['identifier'] for t in reversed(types) if t['name'].startswith('iPhone') and 'Pro Max' not in t['name'])
sim = run('xcrun', 'simctl', 'create', 'AgentMux isolated preview', device, runtime)
try:
    subprocess.run(['xcodegen', 'generate'], cwd=repo / 'ios', check=True)
    subprocess.run(['xcodebuild', '-skipPackagePluginValidation', '-project', str(repo / 'ios/AgentMux.xcodeproj'), '-scheme', 'AgentMux', '-configuration', 'Debug', '-destination', 'id=' + sim, '-derivedDataPath', str(repo / 'build/ui-preview'), 'CODE_SIGNING_ALLOWED=NO', 'build'], check=True)
    if not args.build_only:
        run('xcrun', 'simctl', 'boot', sim)
        run('xcrun', 'simctl', 'bootstatus', sim, '-b')
        app = repo / 'build/ui-preview/Build/Products/Debug-iphonesimulator/AgentMux.app'
        run('xcrun', 'simctl', 'install', sim, str(app))
        run('xcrun', 'simctl', 'ui', sim, 'appearance', 'light' if args.light else 'dark')
        run('xcrun', 'simctl', 'status_bar', sim, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100')
        flags = ['--preview-ui']
        if args.screen in ['text', 'micro', 'glide', 'keyboard']:
            flags += ['--preview-terminal', '--preview-' + args.screen]
        elif args.screen != 'sessions':
            flags += ['--preview-chat', '--preview-' + args.screen]
        output = (repo / args.output).resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        # App writes after its real layout pass. Poll its sandbox output, not a mock renderer.
        container = Path(run('xcrun', 'simctl', 'get_app_container', sim, 'dev.agentmux.app', 'data'))
        capture = container / 'Documents/workbench.png'
        run('xcrun', 'simctl', 'launch', sim, 'dev.agentmux.app', *flags, '--preview-output', str(capture))
        import time
        for _ in range(100):
            if capture.exists():
                # Simulator screenshot includes the system keyboard; drawHierarchy alone does not.
                run('xcrun', 'simctl', 'io', sim, 'screenshot', str(output))
                print('Actual iOS simulator layout (offline fixture):', output)
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('SwiftUI preview timed out')
finally:
    subprocess.run(['xcrun', 'simctl', 'shutdown', sim], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun', 'simctl', 'delete', sim], check=True)
