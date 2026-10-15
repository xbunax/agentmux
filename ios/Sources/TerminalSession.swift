import SwiftUI
import Foundation

struct TerminalAttachment: Decodable {
    struct Capabilities: Decodable { let key: Bool; let paste: Bool; let multiline_paste: Bool }
    let generation: String; let cols: Int; let rows: Int; let command: String; let capabilities: Capabilities
}
struct TerminalFrame: Decodable { let type: String; let data: String?; let cols: Int?; let rows: Int?; let reason: String? }
struct TerminalInput: Encodable {
    var sequence: UInt64 = 0
    var request_id = UUID().uuidString
    let kind: String
    var key = ""
    var text = ""
    var confirm_multiline = false
}

@MainActor final class TerminalSessionModel: ObservableObject {
    @Published var active = false
    @Published var connecting = false
    @Published var uncertain = false
    @Published var status = "确认目标后连接"
    @Published var attachment: TerminalAttachment?
    @Published var native: ChatSnapshot?
    @Published var writing = false
    var output: ((Data, Int?, Int?) -> Void)?
    var browse: ((CGFloat, CGFloat) -> Void)?
    private(set) var session: AgentSession
    private weak var client: Client?
    private var channel: TerminalHTTPStream?
    private var streamTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var nativeTask: Task<Void, Never>?
    private var epoch = UUID()
    private var sequence: UInt64 = 0
    private var queue: [TerminalInput] = []
    private var pendingOutput: [(Data, Int?, Int?)] = []
    init(session: AgentSession) { self.session = session }
    var paneID: String? { session.mode == "plugin" ? session.nativePaneID : ["tmux", "generic"].contains(session.mode) ? session.id : nil }
    var nativeBase: String? { session.mode == "plugin" ? "/v1/plugins/\(session.id)" : nil }
    var canSendNative: Bool { active && !uncertain && native?.alive == true && native?.capabilities?.message == true }
    var canWrite: Bool { active && !uncertain && !connecting }
    func bindOutput(_ handler: @escaping (Data, Int?, Int?) -> Void) {
        output = handler
        for (data, cols, rows) in pendingOutput { handler(data, cols, rows) }
        pendingOutput.removeAll()
    }
    private func deliver(_ data: Data, cols: Int?, rows: Int?) {
        if let output { output(data, cols, rows) }
        else if pendingOutput.count < 64 { pendingOutput.append((data, cols, rows)) }
        else { stop(); status = "终端显示未就绪，请重新打开" }
    }
    func connect(_ client: Client) {
        stop(); self.client = client
        guard let paneID, let profile = client.paired else { return }
        let epoch = self.epoch
        connecting = true; status = "正在连接原终端…"; uncertain = false
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                struct Open: Encodable { let expected_agent_pid: UInt32?; let generic: Bool }
                let body = Open(expected_agent_pid: session.mode == "plugin" ? session.nativeAgentPID : session.agentPID, generic: session.mode == "generic")
                let data = try await client.request("/v1/terminal/panes/\(paneID)/open", method: "POST", body: JSONEncoder().encode(body))
                let attachment = try JSONDecoder().decode(TerminalAttachment.self, from: data)
                guard self.epoch == epoch, !Task.isCancelled else {
                    _ = try? await client.request("/v1/terminal/streams/\(attachment.generation)", method: "DELETE"); return
                }
                self.attachment = attachment
                let channel = try await client.ssh.terminalStream(profile: profile, generation: attachment.generation)
                guard self.epoch == epoch, !Task.isCancelled else { channel.close(); return }
                self.channel = channel
                for try await bytes in channel.frames {
                    guard self.epoch == epoch, !Task.isCancelled else { return }
                    let event = try JSONDecoder().decode(TerminalFrame.self, from: bytes)
                    if event.type == "closed" { throw SSHConnectionError.message(event.reason ?? "目标已变化") }
                    if event.type == "ready" { active = true; connecting = false; status = "实时终端 · \(paneID)"; pollNative(epoch: epoch) }
                    if let encoded = event.data, let data = Data(base64Encoded: encoded) { deliver(data, cols: event.cols, rows: event.rows) }
                }
                if self.epoch == epoch { stop(); status = "连接已结束 · 重新确认目标后继续" }
            } catch {
                guard self.epoch == epoch else { return }
                let wasWriting = writing
                stop(); uncertain = wasWriting
                status = wasWriting ? "结果待确认 · 查看现场后再操作" : "连接已停止：\(error.localizedDescription)"
            }
        }
    }
    func stop() {
        epoch = UUID(); active = false; connecting = false
        queue.removeAll(); pendingOutput.removeAll(); sequence = 0
        streamTask?.cancel(); streamTask = nil; nativeTask?.cancel(); nativeTask = nil
        writeTask?.cancel(); writeTask = nil; writing = false; native = nil
        channel?.close(); channel = nil
        if let generation = attachment?.generation, let client {
            Task { _ = try? await client.request("/v1/terminal/streams/\(generation)", method: "DELETE") }
        }
        attachment = nil
    }
    func cancelNavigation() { queue.removeAll { $0.kind == "key" && ["Up", "Down", "Left", "Right"].contains($0.key) } }
    func key(_ key: String) { enqueue(TerminalInput(kind: "key", key: key)) }
    func committed(_ text: String) {
        if text == "\n" { key("Enter") }
        else if text == "\t" { key("Tab") }
        else { enqueue(TerminalInput(kind: "text", text: text)) }
    }
    func paste(_ text: String, confirmed: Bool = false) { enqueue(TerminalInput(kind: "paste", text: text, confirm_multiline: confirmed)) }
    private func enqueue(_ input: TerminalInput) {
        guard canWrite else { return }
        guard queue.count < 12 else { stop(); uncertain = true; status = "输入队列已满，已停止；请检查现场"; return }
        queue.append(input); drain()
    }
    private func drain() {
        guard writeTask == nil, canWrite, let client, let generation = attachment?.generation else { return }
        let epoch = self.epoch
        writeTask = Task { [weak self] in
            guard let self else { return }
            writing = true
            defer { if self.epoch == epoch { writing = false; writeTask = nil } }
            while !queue.isEmpty && self.epoch == epoch && !Task.isCancelled {
                var input = queue.removeFirst(); sequence += 1; input.sequence = sequence
                do { try await client.send("/v1/terminal/streams/\(generation)/input", value: input) }
                catch {
                    guard self.epoch == epoch else { return }
                    stop(); uncertain = true; status = "结果待确认：\(error.localizedDescription)"; return
                }
            }
        }
    }
    private func pollNative(epoch: UUID) {
        guard let client, let base = nativeBase else { return }
        nativeTask = Task { [weak self] in
            guard let self else { return }
            while self.epoch == epoch && !Task.isCancelled {
                do {
                    let value: ChatSnapshot = try await client.get(base + "/chat")
                    guard self.epoch == epoch else { return }
                    guard value.agentPID == session.agentPID else { native = nil; return }
                    native = value
                } catch { if self.epoch == epoch { native = nil } }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func nativeSend(_ text: String) {
        guard canSendNative, !writing, writeTask == nil, let client, let base = nativeBase else { return }
        let epoch = self.epoch
        writing = true
        writeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == epoch { writing = false; writeTask = nil; drain() } }
            do {
                try await client.send(base + "/actions", value: ChatAction(action: "message", text: text, requestID: UUID().uuidString, agentPID: session.agentPID))
                guard self.epoch == epoch else { return }
                status = "已交给原会话 · 草稿保留"
            } catch {
                guard self.epoch == epoch else { return }
                stop(); uncertain = true; status = "发送结果待确认 · 未自动改走终端"
            }
        }
    }
}

#if DEBUG
extension TerminalSessionModel {
    func preview() {
        active = true; status = "离线布局预览 · 不连接真实 Agent"
        let fixture = """
        {"generation":"00000000-0000-0000-0000-000000000000","cols":48,"rows":28,"command":"codex","capabilities":{"key":true,"paste":true,"multiline_paste":true}}
        """
        attachment = try? JSONDecoder().decode(TerminalAttachment.self, from: Data(fixture.utf8))
        let screen = "\u{1B}c\u{1B}[?25l\u{1B}[1;1H\u{1B}[1;36mAgentMux / terminal workbench\u{1B}[0m\r\n\r\n  Original session · %3\r\n  Mac pane size stays unchanged\r\n\r\n\u{1B}[32m❯ Unknown TUI menu\u{1B}[0m\r\n\r\n  › Review changes\r\n    Continue editing\r\n    Open advanced options…\r\n\r\n  ↑ / ↓ navigate    Enter confirm\r\n  Esc back\r\n\r\n\u{1B}[2mNo menu parser required.\u{1B}[0m\r\n\r\n中文输入 · 保留原来的会话\r\n\r\n  draft on Mac: /model\r\n\u{1B}[?25h"
        deliver(Data(screen.utf8), cols: 48, rows: 28)
    }
}
#endif
