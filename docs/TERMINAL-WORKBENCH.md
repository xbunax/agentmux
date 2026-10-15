# Terminal workbench — first implementation

## Repository audit (base 049c9e5)

The iOS client currently renders transcript messages and parsed menu cards. It has no terminal emulator. `/output` is a capture-pane text snapshot; `/chat` polls transcript/parsed state. Unknown panes are hidden. `relay::action(menu_search)` clears the remote input with C-a/C-k. Native plugin and daemon-managed sessions are distinct; linking a plugin to tmux requires a matching provider and PID. Existing SSH pinning, device authentication and loopback HTTP remain the transport boundary.

`AGENT-INTEGRATION.md` describes the earlier chat-first design, and some of its plugin capability rows lag `INTERACTION-PLUGINS.md`. Neither document is evidence that an arbitrary live TUI exposes a native API.

## First-stage design

- A real SwiftTerm emulator above one adjustable workbench. Text / Micro / Glide replace the same left-hand area; the right rail uses 44 pt minimum targets.
- tmux control-mode output over a streaming, authenticated HTTP channel inside existing SSH forwarding. Capture only bootstraps the active screen. No periodic text-screen polling. Fixed remote grid, local scrolling; never call resize-window or refresh-client -C.
- Terminal write capabilities belong to a stream generation bound to server socket/PID/start time, pane PID/start time and foreground process identity. Closing, revocation, target changes, backpressure or stream failure invalidate that generation. This is not an exclusive lock against the Mac keyboard.
- Ordered, bounded mobile input. Explicit key names, separate Enter/Esc, no gesture confirmation. No offline replay. Request sequence and IDs reject duplicates; errors never automatically retry.
- Local drafts persist per host/session. Terminal paste never clears existing text and never appends Enter. Multiline paste requires the pane's bracketed-paste mode plus explicit user confirmation; no universal no-submit guarantee.
- A distinct terminal-input receiver buffers IME marked text locally and forwards committed text only. Editor and terminal never receive input together.
- Existing plugin capabilities enable native send and structured enhancements. No semantic approval from parsed terminal text. Managed sessions without a pane retain ChatView.
- Unknown panes are explicitly exposed through a generic-terminal selector, with target confirmation before input.

## Scope and compatibility boundaries

Control mode supplies live bytes, not a complete terminal-state serialization. Bootstrap restores active-screen cells, cursor, common modes and scroll region. Pre-attachment scrollback, inactive alternate-screen contents, graphics, custom tab stops, arbitrary terminal extension state and full mouse/Kitty keyboard support are not promised. Local keyboard/viewport changes do not resize the remote pane; an external pane resize ends the stream and requires a fresh snapshot. No new provider SDKs are introduced.

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

`待确认 → 连接中 → 可操作`；断线、目标进程改变、远端 resize、后台挂起或队列溢出转为 `已停止`。写入超时转为 `结果待确认`。重新连接创建新 generation，不重放旧输入。切换会话只改变目标，未发送的方向键排队被取消，已经进入 tmux 的输入无法撤回。

手机草稿与远端编辑区相互独立。填入前显式确认，保留最近一次副本，禁止相同内容无意连续提交；再次填入需要单独操作。IME marked text 不过网络，切换输入接收方时停止旧 receiver。直输多行粘贴单独确认，不覆盖本地草稿。附件上传只把 Mac 路径加入本地草稿；原生增强继续支持现有结构化附件协议。

Micro 快捷键可选择最多六个已有会话，不模拟任何外部硬件身份。滑控在手势开始时固定“浏览 / 方向键”的含义；方向键每 120ms 至多一次，客户端队列最多 12 项，结束手势丢弃尚未发送的导航。第一阶段没有长按自动重复，也没有拟真旋钮动画。

## 终端方案和取舍

采用 tmux Control Mode + SwiftTerm 1.20.0，而非另开 SSH PTY 启动/attach 一个替代 Agent。既有 SSH 连接只转发到本机 loopback API，没有增加公网端口。Control Mode 客户端使用 `ignore-size`，手机在固定远端网格上滚动/缩放。初始屏幕通过同一 control client 的连续命令获取活动屏、光标/常见模式、未完成控制序列；后续转发原始 `%output` 字节，跨事件拆分的 UTF-8 不做有损字符串转换。

身份检查每 700ms 执行，并且每次写入前再次检查；它不是输出快照轮询。身份包括 tmux socket、服务 PID/启动时间、pane PID/启动时间、前台进程组及命令、可选 Agent PID。进程身份检查与 tmux 写入之间仍存在 OS 级调度窗口，不能声称实现 Mac/手机跨设备排他锁或原子进程切换保护；这属于必须真机压力验证的边界。

单行/多行文本上限 16 KiB，拒绝注入控制序列。多行要求 tmux 可报告当前 `bracket_paste_flag`；tmux 3.4 / 3.5a 源码没有该字段，按不支持处理，不猜测版本或屏幕内容。确认后在 tmux 命令队列内检查模式再执行 `paste-buffer -p -r`。远端应用如何解释 bracketed paste 仍需逐个测试。

原始无 generation 的 `/v1/sessions/{id}/input`、`/interrupt` 已返回 410；旧客户端需与 daemon 一起更新。历史受保护的 `/actions` 协议仍为插件/兼容性测试保留，新的终端工作台不使用其屏幕解析菜单路由。`menu_search` 不再清空 Mac 输入区。

上游依据：

- [tmux Control Mode](https://github.com/tmux/tmux/wiki/Control-Mode)
- [tmux 3.4 source](https://github.com/tmux/tmux/tree/3.4)（capture-pane、paste-buffer 与格式实现）
- [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0)（UIKit API 与包插件已查看）
- [Apple glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))（iOS 26，旧系统使用 material，降低透明度时不透明）

后续：先通过当前测试矩阵与真机验收，再扩展终端初始状态/历史、可访问性与大字号，最后按实际同会话能力接入 OpenCode / Gemini CLI / ACP；不以 SDK 存在推断能接管任意 TUI。
