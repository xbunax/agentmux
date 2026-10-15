# Terminal workbench

## Historical repository audit (base 049c9e5)

The iOS client currently renders transcript messages and parsed menu cards. It has no terminal emulator. `/output` is a capture-pane text snapshot; `/chat` polls transcript/parsed state. Unknown panes are hidden. `relay::action(menu_search)` clears the remote input with C-a/C-k. Native plugin and daemon-managed sessions are distinct; linking a plugin to tmux requires a matching provider and PID. Existing SSH pinning, device authentication and loopback HTTP remain the transport boundary.

`AGENT-INTEGRATION.md` describes the earlier chat-first design, and some of its plugin capability rows lag `INTERACTION-PLUGINS.md`. Neither document is evidence that an arbitrary live TUI exposes a native API.

## Current design

- A real SwiftTerm emulator above an independently allocated, hideable workbench. Text / Micro / Glide share a horizontal mode strip with 44 pt minimum targets. Session selection connects directly; no second confirmation dialog.
- tmux control-mode output over a streaming, authenticated HTTP channel inside existing SSH forwarding. Capture only bootstraps the active screen. No periodic text-screen polling. Fixed remote grid and local scrolling by default. Opt-in viewport following uses generation-bound resize requests and fresh snapshots after each accepted change.
- Terminal write capabilities belong to a stream generation bound to server socket/PID/start time, pane PID/start time and foreground process identity. Closing, revocation, target changes, backpressure or stream failure invalidate that generation. This is not an exclusive lock against the Mac keyboard.
- Ordered, bounded mobile input. Explicit key names, separate Enter/Esc, no gesture confirmation. No offline replay. Request sequence and IDs reject duplicates; errors never automatically retry.
- Local drafts persist per host/session. Terminal paste never clears existing text and never appends Enter. Tapping Fill Terminal appends immediately without a second dialog, including multiline text when bracketed-paste mode is available. The explicit action sets the protocol's confirm_multiline flag; the server still checks the current mode. Switching input modes alone does not paste. No universal no-submit guarantee.
- A distinct terminal-input receiver buffers IME marked text locally and forwards committed text only. Editor and terminal never receive input together.
- Existing plugin capabilities enable native send and structured enhancements. No semantic approval from parsed terminal text. Managed sessions without a pane retain ChatView.
- Unknown panes are explicitly exposed through a generic-terminal selector; selecting a pane connects it after server-side identity checks.

## Scope and compatibility boundaries

Control mode supplies live bytes, not a complete terminal-state serialization. Bootstrap restores active-screen cells, cursor, common modes and scroll region. Pre-attachment scrollback, inactive alternate-screen contents, graphics, custom tab stops, arbitrary terminal extension state and full mouse/Kitty keyboard support are not promised. Local keyboard/viewport changes resize the window only when following is enabled. Unexpected external resize ends the stream; input is never replayed. No new provider SDKs are introduced.

## Modules

`src/terminal.rs`: discovery, attachment, stream lifecycle, identity checks and validated input. `SSHTransport.swift`: bounded streaming HTTP over pinned SSH. `TerminalWorkbench.swift`, `TerminalSurface.swift`, `TerminalSession.swift`: terminal rendering, input ownership, drafts, navigation and capability routing. Existing chat, attachments, native adapters and file browser stay available.

## Verification

See TERMINAL-VERIFICATION.md for executed checks and explicit gaps. Linux cannot build UIKit/SwiftUI or produce actual iOS screenshots. Offline SwiftUI preview launch modes and a simulator screenshot script are supplied; do not label conceptual previews as device renders.

## 输入职责与状态

| 操作 | 实现与边界 |
| --- | --- |
| terminal.key | 明确按键白名单；Enter / Esc / Ctrl-C 使用真实名称 |
| terminal.paste | 填入当前焦点，不清空、不追加 Enter；私有临时 tmux buffer |
| agent.sendMessage | 仅绑定插件实际声明 `message` 能力时启用，仍是原进程 |
| agent.answer | 保留原生请求 ID / 状态校验；终端不生成语义审批按钮 |
| agent.interrupt | 原生增强沿用实际 abort 能力；通用键盘的 Ctrl-C 不称为暂停 |

`选择会话 → 连接中 → 可操作`；断线、目标进程改变、远端 resize、后台挂起或队列溢出转为 `已停止`。写入超时转为 `结果待确认`。重新连接创建新 generation，不重放旧输入。切换会话只改变目标，未发送的方向键排队被取消，已经进入 tmux 的输入无法撤回。

手机草稿与远端编辑区相互独立。点击填入直接追加，保留最近一次副本；按钮随后显示“再次填入”，重复填入仍需再次点击。IME marked text 不过网络，切换输入接收方时停止旧 receiver。直输多行粘贴直接填入，不再弹出二次确认，也不覆盖本地草稿。附件上传只把 Mac 路径加入本地草稿；原生增强继续支持现有结构化附件协议。

Micro 快捷键可选择最多六个已有会话，不模拟任何外部硬件身份。滑控在手势开始时固定“浏览 / 方向键”的含义；方向键每 120ms 至多一次，客户端队列最多 12 项，结束手势丢弃尚未发送的导航。第一阶段没有长按自动重复，也没有拟真旋钮动画。

## 终端方案和取舍

采用 tmux Control Mode + SwiftTerm 1.20.0，而非另开 SSH PTY 启动/attach 一个替代 Agent。既有 SSH 连接只转发到本机 loopback API，没有增加公网端口。Control Mode 客户端使用 `ignore-size`；默认只在本地滚动/缩放，显式开启尺寸跟随后才调整目标窗口。初始屏幕通过同一 control client 的连续命令获取活动屏、光标/常见模式、未完成控制序列；后续转发原始 `%output` 字节，跨事件拆分的 UTF-8 不做有损字符串转换。

身份检查每 700ms 执行，并且每次写入前再次检查；它不是输出快照轮询。身份包括 tmux socket、服务 PID/启动时间、pane PID/启动时间、前台进程组及命令、可选 Agent PID。进程身份检查与 tmux 写入之间仍存在 OS 级调度窗口，不能声称实现 Mac/手机跨设备排他锁或原子进程切换保护；这属于必须真机压力验证的边界。

单行/多行文本上限 16 KiB，拒绝注入控制序列。多行要求 tmux 可报告当前 `bracket_paste_flag`；tmux 3.4 / 3.5a 源码没有该字段，按不支持处理，不猜测版本或屏幕内容。点击填入或主动粘贴后，在 tmux 命令队列内检查模式再执行 `paste-buffer -p -r`。远端应用如何解释 bracketed paste 仍需逐个测试。

原始无 generation 的 `/v1/sessions/{id}/input`、`/interrupt` 已返回 410；旧客户端需与 daemon 一起更新。历史受保护的 `/actions` 协议仍为插件/兼容性测试保留，新的终端工作台不使用其屏幕解析菜单路由。`menu_search` 不再清空 Mac 输入区。

上游依据：

- [tmux Control Mode](https://github.com/tmux/tmux/wiki/Control-Mode)
- [tmux 3.4 source](https://github.com/tmux/tmux/tree/3.4)（capture-pane、paste-buffer 与格式实现）
- [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0)（UIKit API 与包插件已查看）
- [Apple glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))（iOS 26，旧系统使用 material，降低透明度时不透明）

后续：先通过当前测试矩阵与真机验收，再扩展终端初始状态/历史、可访问性与大字号，最后按实际同会话能力接入 OpenCode / Gemini CLI / ACP；不以 SDK 存在推断能接管任意 TUI。

## Liquid Glass, palettes and input visibility

`DesignSystem.swift` exposes an environment-driven `AppTheme` with AgentMux, Gruvbox, Catppuccin, Nord and Solarized palettes. Every themed view reads that environment; UIKit terminal colors update in place only when palette/appearance changes. SwiftTerm's explicit ANSI/true-color backgrounds remain meaningful. iOS 26 uses native glass, older systems use Material, and Reduce Transparency uses opaque surfaces.

The three modes remain 文本 / Micro / 滑控. Hiding removes the whole workbench and leaves a 44 pt restore action outside the terminal. Direct terminal browsing hides it after the gesture; Glide browsing hides only after an actual movement completes. Arrow gestures, programmatic scrolling and active keyboard editing do not hide the panel. Manual hiding dismisses the keyboard and cancels queued navigation while preserving drafts. Glide haptics are local acknowledgements, throttled to one per accepted arrow action (120 ms minimum); browsing has one light pulse per moving gesture. System dictation is invoked through the user's keyboard microphone, never by an App recording service.

## Viewport resize protocol

`POST /v1/terminal/streams/{generation}/input` additionally accepts `kind: "resize"`, `enabled`, `cols`, `rows`, and the existing `sequence` / `request_id`. Enabled grids must be 2–1000 cells in each dimension. Open responses advertise optional `capabilities.resize`; old clients ignore it and new clients keep fixed sizing on old daemons.

Resize runs in the stream task, serialized behind the generation's write mutex. The control-mode metadata/capture/pending-byte sequence forms a new snapshot barrier. The `resized` frame carries actual pane dimensions and full bootstrap bytes; `resize_rejected` carries a user-readable reason and leaves the stream available. The client coalesces viewport updates at 250 ms, pauses new input until the snapshot arrives, and keeps the direct-input keyboard mounted during that pause to avoid keyboard/resize feedback loops.

A generation owns a window's size, not just a device credential. A different generation cannot resize it; replacing a device's stream first retires and restores the old generation. The saved original size, layout and inherited/local window-size policy are restored on disable, close and detected transport loss. Mac edits to size/layout/policy cause preservation of the Mac state rather than restoration. Zoomed windows reject following. The requested grid describes the target pane: multi-pane windows reserve space for siblings, resize the window, then explicitly size the target pane. This preserves the split tree instead of shrinking the target to a fraction of the phone viewport. Snapshots report actual dimensions, including any tmux minimum-size constraints.

The atomic state journal `terminal-sizes.json` supports daemon restart recovery. Recovery checks tmux server/pane identity and the last applied window state before restoring. A crash between a tmux mutation and its journal update, or a concurrent Mac edit during the OS-level command sequence, cannot be made transactionally atomic; mismatched state is preserved instead of overwritten. Recovery failures remain journaled for a later startup.

## Grouped browsing and draft input

Settings, files, sessions and supporting lists use native inset groups: one continuous surface per section, inset separators and consistent spacing. Liquid Glass remains on navigation, search and workbench controls; content rows no longer stack independent glass outlines. File browsing adds current-folder search, compact folder rows and a separate path editor. Drafts use an expanding text field with paste and keyboard dictation, keep a local copy, and always append via the terminal paste path without adding Enter. Native provider send remains available in the enhanced chat screen.
