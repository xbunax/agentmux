# Verification record

## SSH connection update — 2026-10-15

Implemented normal Mac SSH login as the primary iOS connection flow. The app checks the host fingerprint before authentication, discovers the running daemon over SSH, enrolls a device, and forwards API requests through the same connection. QR remains optional.

Validated locally on macOS with Xcode 26.4:

| Check | Result |
| --- | --- |
| Rust unit tests | 9 passed: configuration generation/preservation, executable detection, authentication, confinement, ticket expiry, and credential hashing/persistence |
| Rust formatting and Clippy | Passed with warnings denied |
| Release daemon | Compiled successfully |
| HTTP/tmux/file smoke tests | Passed, using temporary roots and an isolated tmux socket |
| Normal SSH interoperability | The actual iOS transport passed against an independent Paramiko 3.5.1 server with AgentMux's port-9848 listener disabled |
| SSH authentication | Password and passphrase-protected OpenSSH Ed25519 login passed |
| Discovery and device lifecycle | Automatic enrollment, exact device-name quoting, API forwarding, saved-profile reconnect, and revocation passed |
| Failure cases | Wrong password, missing discovery file, changed host key, unauthenticated enrollment, and enrollment using a device credential were rejected |
| QR interoperability | The actual iOS transport passed ticket exchange, reconnect, forwarding, and revocation against the Rust SSH listener |
| Agent fixtures | Pi, Codex, and Claude fake-protocol initialization, model selection, structured replies, commands, and deduplication passed |
| iOS device build | Unsigned arm64 Release IPA compiled and packaged successfully |

The camera implementation now serializes configuration, start, and stop, and prevents a late permission callback from starting a dismissed scanner. The dedicated SSH bridge now preserves half-close semantics so response delivery can finish before channel teardown.

## Remaining device and provider checks

- Install the updated app on a physical iPhone and exercise normal SSH login against macOS Remote Login.
- Test camera permission prompts, repeated scanner dismissal, foreground/background transitions, and reconnect on the phone. The reported camera exception has not been retested on hardware here.
- Complete a real tool-using task with each provider, including approvals and cancellation. Fake-agent tests do not establish installed-provider compatibility.
- Validate RSA authentication against the intended SSH server; support depends on its accepted signature algorithms.

Run commands and prerequisites are documented in `README.md`. No live provider requests were made for this verification.
