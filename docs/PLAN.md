# Implementation status and remaining milestones

## Milestone A — developer prototype (implemented, verification recorded separately)

Rust Axum service; localhost auth; tmux pane list/capture/send/interrupt; creation in approved directories; revisioned phone-editable directory settings; SwiftUI app; bounded file transfers; unsigned IPA script.

Existing tmux processes are not structurally adopted. Version 0.2 adds the mobile SSH and structured UI implementation below; runtime verification is tracked independently.

## Milestone B — QR pairing and mobile SSH (implemented, interoperability testing)

Citadel 0.12.1 is pinned. Rust russh provides a dedicated port-9848 SSH endpoint, limited to API forwarding (no remote shell). A locally issued five-minute QR contains a one-use bootstrap credential and the Ed25519 public host key. The App scans by camera/photo, shows the host/fingerprint, pins the key, exchanges the ticket for a revocable device credential and stores the profile in Keychain. It opens direct TCP/IP channels internally; no macOS SSH credentials need to be typed or exported.

Acceptance still requires: runtime interoperability, real-device installation and foreground/background recovery. Compiling an arm64 IPA is not device-connectivity evidence.

Normal Mac SSH login is now the primary connection flow: inspect and pin the host key, authenticate with password or an OpenSSH key, discover the private service descriptor, then enroll a revocable device credential over SSH. All API requests continue through that SSH connection. QR remains optional. Camera configuration/start/stop share one serial queue to prevent teardown during capture configuration.

## Milestone C — structured adapters (implemented, provider testing)

Record actual installed versions and official protocols for Codex, Claude Code and Pi. Test session creation, streaming events, cancellation, permissions, supported model selection, slash command enumeration, session resume, and GUI/terminal capability differences independently. Pi-specific implementation must follow its installed SDK/RPC/extension documentation.

Implemented daemon-owned child-process adapters for Pi RPC, Codex app-server and Claude bidirectional stream-json. Common snapshots include messages, models, commands, approvals and status. iOS exposes chat/tool rendering, cancellation, native model selection and a capability-driven command panel. Existing tmux processes stay terminal-only. No screen scraping as the primary structured protocol. Provider sessions end when the daemon exits; persistence/resume is a separate milestone.

Acceptance: one real complete tool-using task per provider, including approval and cancellation, with capability-driven UI. No fake model dropdowns.

## Milestone D — reliability

SQLite event persistence and per-session sequence numbers, WebSocket subscriptions and replay; idempotent message IDs; single-writer leases; permission requests survive reconnect without automatic approval. Separate terminal bridge from agent transport ownership. Add explicit lifecycle/recovery semantics for daemon restart, agent exit and Mac sleep.

Acceptance: duplicate requests never execute twice, reconnect recovers committed events, terminal and GUI controllers do not interleave messages.

## Milestone E — packaging / operations

launchd install/uninstall, protected configuration directory, per-device revocable credentials, service status/logs/restart from App, configurable upload quotas, transfer cancellation and cleanup, secure audit events, production security review. Keep SSH enablement and initial root approval local. No silent public binding or remote executable replacement.

Acceptance: clean Mac installation, upgrade/rollback, independently signed iPhone installation and real-device end-to-end tests. An unsigned IPA alone is not installability evidence.

## Milestone F — embedded iroh and QR pairing

Add iroh beside SSH, inside the daemon process. Local `agentmuxd pair --transport iroh` starts the endpoint and enables it for subsequent launches. A version-2 QR contains the daemon's public EndpointId, address hints, relay configuration, a single-use random ticket, and a five-minute expiry. Generating a new code invalidates the previous iroh code. Neither private identities nor permanent credentials are embedded.

The official Swift IrohLib 1.1.0 SDK requires iOS 17.5; daemon iroh is pinned at 1.3.0. Their interoperability is checked using the actual client transport against an isolated Rust daemon. This raises the minimum iOS version from 17.0 to 17.5.

An authenticated QUIC connection carries bounded API requests on independent bidirectional streams, using ALPN `agentmux/api/1`; initial enrollment uses `agentmux/pair/1`. Existing Axum handlers enforce file confinement, authorization, terminal ownership, generation and input sequence checks. A response supports bounded streaming chunks, including existing terminal NDJSON. No arbitrary TCP forwarding or remote shell is exposed. Reconnect never resends an input request or switches to SSH.

Daemon identity is stored at `~/.config/agentmux/state/iroh.key` (0600). Device credentials remain hashed in devices.json and bind to the enrolled mobile EndpointId. Phone identity and saved profiles are stored in Keychain; legacy SSH profiles migrate without losing their credentials. Revoking a device invalidates subsequent requests immediately and closes its active connections. HTTP remains loopback-only, SSH pinning remains intact.

Default discovery/relay uses the public n0 network, with optional `iroh.relay_urls` for self-hosted relays. Relays carry encrypted traffic; discovery/relay infrastructure can observe routing metadata. An empty relay list selects offline direct-only mode, used by automated tests. Configuration changes to relay selection take effect after a daemon restart. Existing configurations leave iroh disabled until explicitly paired.

The iOS connection chooser supports camera, photos and pasted pairing JSON, shows the Mac identity before enrollment, and retains separate saved SSH/iroh profiles. Connection details report selected direct/relay paths. Existing Liquid Glass styles, drafts, Micro controls and terminal behavior are reused.

Validation: Rust authentication/expiry/limits tests, Rust-to-Swift pairing and streaming probe, SSH regression, iOS release compile, and GitHub Actions IPA. Real iPhone camera, LAN/cellular transitions, relay-only networks and foreground recovery still require device testing; desktop probes cannot establish those behaviors.

Local verification completed: 46 Rust unit tests; warning-free clippy; terminal API and real isolated tmux regression; actual IrohLib 1.1.0 ↔ Rust iroh 1.3.0 enrollment, ticket reuse rejection, wrong-peer rejection, Unicode terminal input, independent stream cancellation, bounded file round-trip, path confinement, settings compatibility, reconnect, revocation and daemon identity persistence; iOS Release build. LAN/cellular and public-relay behavior on an iPhone remain device acceptance checks.
