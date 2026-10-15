#!/usr/bin/env python3
"""Render real SwiftUI screens through Mac Catalyst, with a network-free debug transport.

No simulator download, Keychain reads, model calls or connection to a real daemon.
Requires Xcode's Mac SDK. Screenshots are component/layout previews, not iPhone tests.
"""
import argparse
import plistlib
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--build-only', action='store_true')
parser.add_argument('--screen', choices=['sessions', 'chat', 'menu', 'commands', 'attachments'], default='sessions')
parser.add_argument('--light', action='store_true')
parser.add_argument('--output', default='build/ui-preview.png')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
build = repo / 'build/ui-preview'
app = build / 'AgentMuxUIPreview.app'
executable = app / 'Contents/MacOS/AgentMuxUIPreview'
executable.parent.mkdir(parents=True, exist_ok=True)
stub = build / 'PreviewTransport.swift'
stub.write_text('''import Foundation
struct SSHLogin: Codable, Equatable, Sendable { var password: String?; var privateKey: String?; var passphrase: String? }
struct PairedMac: Codable, Equatable { let host: String; let port: Int; let username: String; let hostKey: String; let credential: String; let deviceID: String; var sshLogin: SSHLogin? = nil; var apiPort: Int? = nil }
struct SSHResponse: Sendable { let status: Int; let data: Data }
enum SSHConnectionError: LocalizedError { case message(String); var errorDescription: String? { if case let .message(s) = self { return s }; return nil } }
actor SSHTransport {
    func disconnect() async {}
    func inspectHost(host: String, port: Int) async throws -> String { throw SSHConnectionError.message("Preview transport is offline") }
    func connectSSH(host: String, port: Int, username: String, hostKey: String, login: SSHLogin, deviceName: String) async throws -> PairedMac { throw SSHConnectionError.message("Preview transport is offline") }
    func request(profile: PairedMac, path: String, method: String, token: String, body: Data?) async throws -> SSHResponse { throw SSHConnectionError.message("Preview transport is offline") }
}
''')
sources = sorted(path for path in (repo / 'ios/Sources').glob('*.swift') if path.name != 'SSHTransport.swift')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
command = ['xcrun', 'swiftc', '-D', 'DEBUG', '-parse-as-library', '-sdk', sdk,
           '-target', 'arm64-apple-ios17.0-macabi', '-module-cache-path', str(build / 'module-cache'),
           '-F', sdk + '/System/iOSSupport/System/Library/Frameworks',
           '-I', sdk + '/System/iOSSupport/usr/include', '-L', sdk + '/System/iOSSupport/usr/lib',
           *map(str, sources), str(stub), '-o', str(executable)]
if not executable.exists() or any(path.stat().st_mtime > executable.stat().st_mtime for path in sources):
    subprocess.run(command, check=True, cwd=repo)
info = {'CFBundleIdentifier': 'dev.agentmux.ui-preview', 'CFBundleExecutable': 'AgentMuxUIPreview', 'CFBundleName': 'AgentMux UI Preview', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.6.0', 'CFBundleVersion': '6', 'LSMinimumSystemVersion': '14.0', 'NSPrincipalClass': 'NSApplication', 'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
if args.build_only:
    print('Built real SwiftUI pages with debug-only, offline transport: ' + str(app))
else:
    output = (repo / args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.suffix.lower() != '.png': raise ValueError('Preview output must be a PNG file')
    output.unlink(missing_ok=True)
    options = ['--preview-ui', '--preview-output', str(output)]
    if args.screen != 'sessions': options.append('--preview-chat')
    if args.screen == 'menu': options.append('--preview-menu')
    if args.screen == 'commands': options.append('--preview-commands')
    if args.screen == 'attachments': options.append('--preview-attachments')
    if args.light: options.extend(['-appearance', 'light'])
    process = subprocess.Popen([str(executable), *options], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if output.exists():
                print('SwiftUI layout preview (fixture data): ' + str(output)); break
            if process.poll() is not None:
                raise RuntimeError(process.stderr.read().decode()[-3000:])
            time.sleep(.1)
        else: raise RuntimeError('Preview screenshot timed out')
    finally:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
