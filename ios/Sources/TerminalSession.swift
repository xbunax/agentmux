import SwiftUI
import Foundation

struct TerminalAttachment: Decodable {
    struct Capabilities: Decodable { let key: Bool; let paste: Bool; let multiline_paste: Bool; let resize: Bool? }
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
    var enabled = false
    var cols = 0
    var rows = 0
}

struct TerminalGrid: Equatable { let cols: Int; let rows: Int }

@MainActor final class TerminalSessionModel: ObservableObject {
    @Published var active = false
    @Published var connecting = false
    @Published var uncertain = false
    @Published var status = "尚未连接 · 点击连接以继续此会话"
    @Published var attachment: TerminalAttachment?
    @Published var native: ChatSnapshot?
    @Published var writing = false
    @Published var resizing = false
    @Published var grid: TerminalGrid?
    var returnToCursor: (() -> Void)?
    private var resizeTask: Task<Void, Never>?
    private var followSize = false
    private var viewport: TerminalGrid?
    private var lastRequestedGrid: TerminalGrid?
    private var followsRemote = false
    private var resizeBlocked = false
    private var userInputInFlight = false
    var output: ((Data, Int?, Int?) -> Void)?
    var browse: ((CGFloat, CGFloat) -> Bool)?
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
    var canSendNative: Bool { active && !uncertain && !resizing && native?.alive == true && native?.capabilities?.message == true }
    var canWrite: Bool { active && !uncertain && !connecting && !resizing }
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
        guard !active, !connecting else { return }
        stop(); self.client = client
        guard let paneID, let profile = client.paired else { status = "请先连接 Mac，再打开会话"; return }
        let epoch = self.epoch
        connecting = true; status = "正在连接 Mac 上的会话…"; uncertain = false
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
                    if event.type == "ready" {
                        active = true; connecting = false; status = "已连接 · 与 Mac 实时同步"
                        pollNative(epoch: epoch); scheduleResize()
                    }
                    if let cols = event.cols, let rows = event.rows { grid = TerminalGrid(cols: cols, rows: rows) }
                    if event.type == "resized" { resizing = false; scheduleResize() }
                    if event.type == "resize_rejected" {
                        resizing = false; resizeBlocked = true
                        status = event.reason ?? "无法调整尺寸，当前使用固定尺寸"
                    }
                    if let encoded = event.data, let data = Data(base64Encoded: encoded) { deliver(data, cols: event.cols, rows: event.rows) }
                }
                if self.epoch == epoch { stop(); status = "连接已结束 · 点击连接以继续此会话" }
            } catch {
                guard self.epoch == epoch else { return }
                let wasWriting = userInputInFlight
                stop(); uncertain = wasWriting
                status = wasWriting ? "结果待确认 · 查看现场后再操作" : "连接已停止：\(error.localizedDescription)"
            }
        }
    }
    func stop() {
        uncertain = uncertain || userInputInFlight
        userInputInFlight = false
        resizeTask?.cancel(); resizeTask = nil; resizing = false
        lastRequestedGrid = nil; followsRemote = false; resizeBlocked = false
        epoch = UUID(); active = false; connecting = false
        status = uncertain ? "输入结果待确认 · 请查看终端后重试连接" : "已断开 · 点击重试连接"
        queue.removeAll(); pendingOutput.removeAll(); sequence = 0
        streamTask?.cancel(); streamTask = nil; nativeTask?.cancel(); nativeTask = nil
        writeTask?.cancel(); writeTask = nil; writing = false; native = nil
        channel?.close(); channel = nil
        if let generation = attachment?.generation, let client {
            Task { _ = try? await client.request("/v1/terminal/streams/\(generation)", method: "DELETE") }
        }
        attachment = nil
    }
    func setFollowSize(_ enabled: Bool) {
        guard enabled != followSize else { return }
        followSize = enabled; resizeBlocked = false; scheduleResize()
    }
    func setViewport(cols: Int, rows: Int) {
        let next = TerminalGrid(cols: min(1000, max(2, cols)), rows: min(1000, max(2, rows)))
        guard viewport != next else { return }
        viewport = next; scheduleResize()
    }
    private func scheduleResize() {
        resizeTask?.cancel()
        guard active, !uncertain, !resizeBlocked else { return }
        guard attachment?.capabilities.resize == true else {
            if followSize { status = "当前服务不支持尺寸跟随，请更新 Mac 上的 agentmuxd" }
            return
        }
        guard !resizing, !writing, let viewport else { return }
        guard followSize ? (!followsRemote || lastRequestedGrid != viewport) : followsRemote else { return }
        let epoch = self.epoch
        resizeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.epoch == epoch, active, !uncertain, !writing, !resizing else { return }
            resizing = true; followsRemote = followSize; lastRequestedGrid = viewport
            queue.append(TerminalInput(kind: "resize", enabled: followSize, cols: viewport.cols, rows: viewport.rows))
            drain()
        }
    }
    func cancelNavigation() { queue.removeAll { $0.kind == "key" && ["Up", "Down", "Left", "Right"].contains($0.key) } }
    @discardableResult func key(_ key: String) -> Bool { enqueue(TerminalInput(kind: "key", key: key)) }
    func committed(_ text: String) {
        if text == "\n" { key("Enter") }
        else if text == "\t" { key("Tab") }
        else { enqueue(TerminalInput(kind: "text", text: text)) }
    }
    @discardableResult func paste(_ text: String, confirmed: Bool = false) -> Bool {
        enqueue(TerminalInput(kind: "paste", text: text, confirm_multiline: confirmed))
    }
    @discardableResult private func enqueue(_ input: TerminalInput) -> Bool {
        guard canWrite else { return false }
        guard queue.count < 12 else { stop(); uncertain = true; status = "输入队列已满，已停止；请检查现场"; return false }
        returnToCursor?()
        queue.append(input); drain(); return true
    }
    private func drain() {
        guard writeTask == nil, active, !uncertain, let client, let generation = attachment?.generation else { return }
        let epoch = self.epoch
        writeTask = Task { [weak self] in
            guard let self else { return }
            writing = true
            defer { if self.epoch == epoch { writing = false; writeTask = nil; userInputInFlight = false; scheduleResize() } }
            while !queue.isEmpty && self.epoch == epoch && !Task.isCancelled {
                var input = queue.removeFirst(); sequence += 1; input.sequence = sequence
                userInputInFlight = input.kind != "resize"
                do { try await client.send("/v1/terminal/streams/\(generation)/input", value: input) }
                catch {
                    guard self.epoch == epoch else { return }
                    let isInput = userInputInFlight
                    stop(); uncertain = isInput
                    status = isInput ? "结果待确认：\(error.localizedDescription)" : "尺寸调整失败，请重试连接：\(error.localizedDescription)"
                    return
                }
                userInputInFlight = false
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
        writing = true; userInputInFlight = true
        writeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == epoch { writing = false; writeTask = nil; userInputInFlight = false; drain(); scheduleResize() } }
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
