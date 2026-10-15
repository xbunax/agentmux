# Repository Guidelines

## Project Structure & Module Organization

AgentMux connects a Rust macOS daemon to a SwiftUI iOS client through restricted SSH.

- `src/main.rs`: HTTP API, configuration, tmux sessions, and file access.
- `src/agents.rs`: native Pi, Codex, and Claude protocol adapters.
- `src/pairing.rs`: SSH transport, enrollment, and device credentials.
- `ios/Sources/`: SwiftUI views, shared SSH transport, and bundled notices; `ios/project.yml` defines the XcodeGen project.
- `tests/SSHProbe.swift`: macOS probe compiling the actual iOS transport.
- `scripts/`: integration tests, fake agents, configuration, and packaging helpers.
- `docs/PLAN.md`: design plan. Generated artifacts belong in ignored `build/`, `target/`, and `dist/`.

## Build, Test, and Development Commands

Run commands from the repository root. Install Rust, tmux, and Python; iOS builds also require Xcode and XcodeGen.

- `cp agentmux.example.json agentmux.json`: initialize configuration; edit existing roots and agent executable paths before starting.
- `cargo run --bin agentmuxd`: start the development daemon.
- `cargo build --release`: build the optimized daemon.
- `cargo fmt --check`: check Rust formatting.
- `cargo clippy --all-targets -- -D warnings`: enforce warning-free Rust linting.
- `cargo test`: run Rust unit tests.
- `python3 scripts/smoke-test.py`: build and test HTTP, files, and isolated tmux sessions.
- `swift build --scratch-path build/swift-probe --product SSHProbe`: build the transport probe; then run `python3 scripts/test-swift-transport.py` after `cargo build`.
- `sh scripts/build-unsigned-ipa.sh`: export `dist/AgentMux-unsigned.ipa`.

## Coding Style & Naming Conventions

Use four-space indentation. Follow rustfmt for Rust; use `snake_case` functions/modules and `PascalCase` types. Swift uses `lowerCamelCase` members and `UpperCamelCase` types. Python uses `snake_case`; follow existing hyphenated script filenames. No dedicated Swift or Python formatter configuration is checked in.

## Testing Guidelines

Place Rust `#[test]` cases in module-local `#[cfg(test)]` blocks with descriptive behavior names. Integration scripts use Python assertions. No coverage threshold is configured. Add regression checks for authentication, path confinement, and protocol changes.

Stop development daemons before integration tests using ports 9847/9848. SSH agent tests require Paramiko 3.5.1; follow README setup. Their `--live` mode invokes installed providers and may incur cost. Desktop probes do not establish iPhone end-to-end correctness.

## Commit & Pull Request Guidelines

No commit history exists yet. Use concise imperative subjects and focused commits. PRs should explain behavior changes, link relevant issues, list verification results, and include screenshots for UI changes. State device-testing limitations.

## Security & Configuration

Keep `agentmux.json`, `.agentmux/`, credentials, and pairing images out of Git. Keep HTTP loopback-only and preserve SSH host-key pinning. Approved directories do not sandbox agent processes.
