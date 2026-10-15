#if DEBUG
import SwiftUI
import UIKit

/// Explicit debug-only fixture. Never reads Keychain or connects to a host.
enum InterfacePreview {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--preview-ui")
    static let mac = PairedMac(host: "MacBook Pro · 界面预览", port: 22, username: "developer", hostKey: "", credential: "preview-only", deviceID: "preview")
    static let sessions = [
        AgentSession(id: "%preview1", name: "dev:1", directory: "/Users/developer/Projects/agentmux", command: "codex", mode: "tmux", windowID: "@1", windowName: "AgentMux iOS", sessionName: "开发", agentPID: 100),
        AgentSession(id: "%preview2", name: "dev:2", directory: "/Users/developer/Projects/website", command: "claude", mode: "tmux", windowID: "@2", windowName: "界面优化", sessionName: "开发", agentPID: 101),
        AgentSession(id: "%preview3", name: "research:1", directory: "/Users/developer/Projects/research", command: "pi", mode: "tmux", windowID: "@3", windowName: "文档与调研", sessionName: "调研", agentPID: 102),
    ]
    static func pendingFiles() -> [PendingAttachment] {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360))
        let image = renderer.image { context in
            UIColor(red: 0.93, green: 0.96, blue: 0.96, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            UIColor(red: 0.15, green: 0.38, blue: 0.33, alpha: 1).setFill(); UIBezierPath(roundedRect: CGRect(x: 30, y: 30, width: 580, height: 60), cornerRadius: 14).fill()
            for index in 0..<3 {
                UIColor.white.setFill(); UIBezierPath(roundedRect: CGRect(x: 30, y: 110 + index * 75, width: 580, height: 60), cornerRadius: 14).fill()
                UIColor(red: 0.45, green: 0.75, blue: 0.65, alpha: 1).setFill(); UIBezierPath(ovalIn: CGRect(x: 45, y: 120 + index * 75, width: 40, height: 40)).fill()
            }
        }
        return [try? PendingAttachment.store(data: image.pngData()!, name: "界面草图.png"), try? PendingAttachment.store(data: Data("# 界面调整\n\n保持会话交互。".utf8), name: "调整说明.md")].compactMap { $0 }
    }
    static func response(_ path: String, method: String) throws -> Data {
        if method != "GET" { return Data("{\"accepted\":true}".utf8) }
        if path == "/v1/sessions" { return try JSONEncoder().encode(sessions) }
        if ["/v1/managed", "/v1/plugins"].contains(path) { return Data("[]".utf8) }
        if path.hasSuffix("/chat") {
            let isPi = path.contains("preview3")
            let isClaude = path.contains("preview2")
            let commands: [[String: Any]] = [
                ["name": "model", "description": "选择当前会话的模型", "kind": "tui"],
                ["name": "compact", "description": "整理当前会话的上下文", "kind": "tui"],
                ["name": "status", "description": "查看会话状态", "kind": "tui"],
            ]
            var messages: [[String: Any]] = [
                ["id": "u1", "role": "user", "text": "帮我优化一下会话列表，保留已有交互。"],
                ["id": "a1", "role": "assistant", "text": "可以。我会先整理信息层级，让常用操作更容易找到。\n\n**这次调整**\n\n• 会话按工作区分组\n• 支持搜索和置顶\n• 保留消息、命令和审批操作"],
                ["id": "t1", "role": "tool", "text": "", "tool": ["name": "Read · SessionList.swift", "input": "ios/Sources/SessionList.swift", "output": "已读取会话列表组件。", "status": "completed"]],
            ]
            if ProcessInfo.processInfo.arguments.contains("--preview-menu") {
                messages.append(["id": "u2", "role": "user", "text": "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"])
            } else {
                messages.append(["id": "a2", "role": "assistant", "text": "现在可以继续调整聊天页的间距。代码块支持独立复制：\n\n```swift\nSessionList()\n    .tint(AppTheme.accent)\n```"])
            }
            var value: [String: Any] = ["messages": messages, "models": [], "commands": commands, "model": "", "busy": false, "alive": true, "approvals": [], "revision": 1,
                "agent_pid": isPi ? 102 : isClaude ? 101 : 100, "capabilities": ["message": true, "abort": true, "models": false, "approvals": false], "source": "tmux", "notice": "界面预览数据，不连接真实 Agent。"]
            if ProcessInfo.processInfo.arguments.contains("--preview-menu") {
                value["interaction"] = ["id": "preview-menu", "title": "选择模型", "detail": "选择后再确认，保留当前会话。", "options": [
                    ["id": 0, "label": "默认模型", "selected": true], ["id": 1, "label": "快速响应", "selected": false], ["id": 2, "label": "深入思考", "selected": false],
                ]]
            }
            return try JSONSerialization.data(withJSONObject: value)
        }
        if path == "/v1/settings" { return try JSONEncoder().encode(ServiceConfig(revision: 1, roots: ["/Users/developer/Projects"], defaultDirectory: "/Users/developer/Projects/agentmux", agents: Agents(codex: "codex", claude: "claude", pi: "pi"))) }
        if path == "/v1/files" { return try JSONEncoder().encode([FileEntry(name: "ios", directory: true, size: 0), FileEntry(name: "docs", directory: true, size: 0), FileEntry(name: "README.md", directory: false, size: 4800)]) }
        return Data("{}".utf8)
    }
}

struct InterfacePreviewRoot: View {
    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--preview-terminal") {
                NavigationStack { TerminalWorkbench(session: InterfacePreview.sessions[0], availableSessions: InterfacePreview.sessions) }
            } else if ProcessInfo.processInfo.arguments.contains("--preview-chat") {
                NavigationStack { ChatView(session: InterfacePreview.sessions[0], availableSessions: InterfacePreview.sessions) }
            } else { WorkspaceRoot() }
        }.environment(\.horizontalSizeClass, .compact).onAppear {
            #if targetEnvironment(macCatalyst)
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.sizeRestrictions?.minimumSize = CGSize(width: 430, height: 860)
                scene.sizeRestrictions?.maximumSize = CGSize(width: 430, height: 860)
                scene.titlebar?.titleVisibility = .hidden
            }
            #endif
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let args = ProcessInfo.processInfo.arguments
                guard let index = args.firstIndex(of: "--preview-output"), args.indices.contains(index + 1),
                      let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let window = scene.windows.first(where: \.isKeyWindow) else { return }
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try? image.pngData()?.write(to: URL(fileURLWithPath: args[index + 1]))
            }
        }
    }
}
#endif
