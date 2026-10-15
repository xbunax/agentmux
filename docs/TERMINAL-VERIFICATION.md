# Terminal workbench verification

Date: 2026-10-15. Base repository: `049c9e5399c4f37326499b086d99f13100976a90`.

This change is an implementation candidate, not a claim of universal TUI compatibility. No real user Agent received test input, no user tmux server was restarted, and no paid model request was sent.

## Executed locally

| Check | Result | What it establishes |
| --- | --- | --- |
| `cargo fmt --check` | Passed | Rust formatting |
| `CARGO_INCREMENTAL=0 cargo clippy --all-targets -- -D warnings` | Passed | Warning-free Rust static checks |
| `CARGO_INCREMENTAL=0 cargo test` | 39 passed | Includes terminal byte decoding, split UTF-8, bootstrap modes/cursor, control injection and duplicate/out-of-order request protection; existing approval/auth/config tests |
| `CARGO_INCREMENTAL=0 python3 scripts/test-terminal-api.py` | Passed | Real loopback HTTP authentication on terminal routes, 410 legacy writes, malformed pane IDs and expired/missing generations; no tmux mocked as a real terminal |
| Python compilation, shell syntax, `git diff --check` | Passed | Script/patch syntax |
| Tree-sitter Swift parse, all 15 source files | Passed | Syntax only, **not** Swift type checking or iOS compilation |
| `python3 scripts/test-terminal-stream.py` with extracted tmux 3.4 | Blocked | This Linux execution environment denies AF_UNIX socket creation (`EPERM`); `/bin/ps` is also restricted. Not a terminal integration pass |
| Xcode/iOS simulator/device | Not available locally | Linux cannot build UIKit/SwiftUI, capture real iOS layouts or verify IME behavior |

An incremental Rust linker-cache failure was cleared with `cargo clean -p agentmuxd`; subsequent checks used `CARGO_INCREMENTAL=0`. This does not substitute for macOS compilation.

## GitHub Actions

The iOS workflow builds an unsigned arm64 IPA and captures Text / Micro / Glide / keyboard / light-mode layouts from the actual SwiftUI app in an isolated iOS simulator. The terminal workflow runs Rust checks and the isolated real-tmux fixture on Linux and macOS. These updated workflows have **not run**. After the user authorized synchronization, command-line push failed because no GitHub credential was available; the connected GitHub integration also rejected `git/trees` with HTTP 403 `Resource not accessible by integration`. The repository is readable and its account metadata advertises push permission, but that does not grant this integration effective Contents-write access. No remote ref changed. Local commits and an exportable patch are retained pending corrected repository authorization.

The preview app uses explicit DEBUG-only offline fixture bytes; screenshots establish layout, not real Agent compatibility. No hand-drawn or web-rendered picture is presented as an iOS screenshot.

## Required acceptance matrix

| Scenario | Automated coverage supplied | Remaining verification |
| --- | --- | --- |
| Chinese / composed input | Raw UTF-8 unit tests and real-tmux byte fixture | iOS Pinyin marked text, deleting marked text, switching focus while composing; dictation |
| Multiline paste | Confirmation + mode gating, expected bracket wrappers, mode-change rejection | Real tmux supporting the flag and each actual Agent; older tmux must reject safely |
| Existing Mac draft | Fixture retains `existing-text`; verifies no C-a/C-k or extra Enter | Mobile/Mac simultaneous edits in real Agents |
| Slash completion / search / nested menus / unknown popups | Raw key transport fixture with unknown screen; no parser dependency | Actual Codex/Claude/Pi menus and arbitrary CLI behavior |
| Busy Agent + draft | UI permits local editing independent of connection | Native busy/queue semantics and same-session plugin UI on device |
| Rapid target switching / disconnect / pane reuse | Generation/order/duplicate tests; real fixture reconnect, resize and respawn | Real SSH interruption, app backgrounding, gesture in flight and rapid device interaction |
| Navigation repeats | Bounded ordered queue, 120ms gesture throttle, release cancellation in code | Device gesture stress; no long-press autorepeat implemented |
| Expired approvals | Existing native request validation retained | Actual provider stale forms; no Enter/y fallback is offered |
| Keyboard and remote size | Terminal fixture verifies unchanged remote dimensions | Real device show/hide/rotation, Dynamic Type, VoiceOver and reduce-transparency |
| Managed session without pane | Routing keeps structured ChatView | Simulator/device native managed-session regression |

## Known boundaries

- Capture/bootstrap restores the active screen and common modes, not every terminal state. Pre-attach scrollback, inactive alternate buffer, saved cursor/SGR pen, custom tab stops, graphics, mouse and extended keyboard protocols require more work/testing.
- Output backpressure closes the stream rather than silently skipping bytes. Reconnect requires a fresh snapshot and verified target identity; external remote resize also stops the stream.
- Identity checks fail closed if process metadata is unavailable. macOS `ps` behavior and wrappers must pass the real fixture before claiming support.
- No lease can stop a Mac keyboard. A write already dispatched cannot be recalled; OS process-change races remain possible between identity check and tmux execution.
- Old clients using unbound `/input` or `/interrupt` must update with the daemon. Existing native adapters are reused, not replaced or widened to unverified APIs.
- A successful IPA build or fixture screenshot is not real-device or paid-provider end-to-end acceptance.

## 2026-10-16 local macOS update

- `cargo test`: 39 passed; `cargo clippy --all-targets -- -D warnings` passed.
- `python3 scripts/test-terminal-api.py`: passed (live loopback authentication and stale generation protection).
- Isolated tmux 3.8 stream test: passed default unchanged grid, live phone resize and full-screen snapshots, invalid grid and duplicate request rejection, disable/close restoration, generation replacement, Mac-side size preservation, daemon kill/restart recovery, split-pane layout restoration, and pane respawn. Also passed cross-device ownership/403 checks and resize contention rejection. No paid providers invoked.
- `cargo build --release --bin agentmuxd`: passed.
- Device SDK Release build: passed using a directly built SwiftTerm host generator. The standard scheme destination is unavailable because this Xcode installation lacks its iOS platform component despite having an iPhone SDK.
- No installed iOS simulator runtime. Real iPhone haptics, Chinese IME, keyboard transitions and system dictation still require device verification. Catalyst fixture captures, when available, only verify desktop-hosted SwiftUI layout.

The user requested no further UI preview; visual acceptance will be performed by the user. No new screenshot is presented as verified device output.

### Split-pane viewport correction

The previous split test accepted a target narrower than the requested viewport. The corrected regression requires exact target dimensions in a three-pane layout (left agent, two stacked right panes), including shrink/grow transitions and a nested bottom-right target. The isolated tmux stream test passes with original-layout restoration after both targets disconnect. Rust's 39 tests, Clippy, Release daemon build and iOS Release build also pass. The direct-input panel uses less height with the keyboard open; device visual acceptance remains with the user.

### Stable default configuration paths

The default configuration now lives at `~/.config/agentmux/agentmux.json`, with device state in `~/.config/agentmux/state/`. Unit coverage verifies fixed paths, independent explicit overrides, missing HOME handling, private creation and preserving the original project roots when subsequently launched elsewhere. Final Rust suite: 42 passed; formatting, Clippy and release compilation passed. UI compilation passed; previews remain disabled unless explicitly requested via workflow dispatch.
