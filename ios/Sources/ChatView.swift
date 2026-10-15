import SwiftUI

struct ToolDetail: Decodable {
    let name: String; let input: String; let output: String; let status: String
}
struct ChatMessage: Decodable, Identifiable {
    let id: String; let role: String; let text: String; let tool: ToolDetail?
}
struct AgentModel: Decodable, Identifiable {
    let id: String; let name: String; let provider: String
    var key: String { provider + "/" + id }
}
struct SlashCommand: Decodable, Identifiable { var id: String { name }; let name: String; let description: String }
struct AgentQuestionOption: Decodable { let label: String; let description: String }
struct AgentQuestion: Decodable, Identifiable {
    let id: String; let title: String; let prompt: String; let options: [AgentQuestionOption]
    let multiple: Bool; let other: Bool; let secret: Bool
}
struct AgentApproval: Decodable, Identifiable {
    let id: String; let title: String; let detail: String; let options: [String]; let kind: String
    let questions: [AgentQuestion]?
}
struct ChatCapabilities: Decodable { let message: Bool; let abort: Bool; let models: Bool; let approvals: Bool }
struct Conversation: Decodable, Identifiable {
    let id: String; let title: String; let modified: UInt64
    var date: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
}
struct ChatSnapshot: Decodable {
    let messages: [ChatMessage]; let models: [AgentModel]; let commands: [SlashCommand]
    let model: String; let busy: Bool; let alive: Bool; let approvals: [AgentApproval]
    let error: String?; let revision: UInt64
    let capabilities: ChatCapabilities?; let notice: String?; let conversations: [Conversation]?
    let agentPID: UInt32?; let conversationID: String?; let source: String?
    enum CodingKeys: String, CodingKey {
        case messages, models, commands, model, busy, alive, approvals, error, revision, capabilities, notice, conversations, source
        case agentPID = "agent_pid", conversationID = "conversation_id"
    }
}
struct ChatAction: Encodable {
    let action: String
    var text = ""; var model = ""; var provider = ""; var requestID = ""; var approved = false
    var agentPID: UInt32?; var conversationID = ""; var answers: [String: [String]] = [:]
    enum CodingKeys: String, CodingKey {
        case action, text, model, provider, approved, answers
        case requestID = "request_id", agentPID = "agent_pid", conversationID = "conversation_id"
    }
}
struct ChatView: View {
    @EnvironmentObject var client: Client
    @Environment(\.scenePhase) var phase
    let session: AgentSession
    @State private var snapshot: ChatSnapshot?
    @State private var draft = ""
    @State private var sending = false
    @State private var models = false
    @State private var commands = false
    @State private var conversations = false
    @State private var confirmStop = false
    @State private var pendingID = UUID().uuidString
    @State private var connectionError: String?
    private var base: String { session.mode == "structured" ? "/v1/managed/\(session.id)" : "/v1/sessions/\(session.id)" }
    private var canSend: Bool { snapshot?.alive == true && (snapshot?.capabilities?.message ?? (snapshot?.busy == false)) && connectionError == nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(snapshot?.alive == true ? .green : .gray).frame(width: 7, height: 7)
                Text(snapshot?.busy == true ? "正在工作…" : canSend ? "可以发送消息" : "等待就绪").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if snapshot?.models.isEmpty == false {
                    Button(snapshot?.model.isEmpty == false ? snapshot!.model : "选择模型") { models = true }
                        .font(.caption).lineLimit(1).disabled(snapshot?.busy == true)
                }
                if snapshot?.capabilities?.abort ?? (snapshot?.busy == true) {
                    Button { confirmStop = true } label: { Image(systemName: "stop.circle") }.accessibilityLabel("停止当前任务")
                }
            }.padding(.horizontal).padding(.vertical, 10)
            if let error = connectionError ?? snapshot?.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).padding(.horizontal).textSelection(.enabled)
            }
            if let notice = snapshot?.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8)
            }
            if let available = snapshot?.conversations, !available.isEmpty {
                Button { conversations = true } label: {
                    Label(snapshot?.conversationID == nil ? "选择当前对话" : "切换对话记录", systemImage: "text.bubble")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if snapshot?.messages.isEmpty == true {
                            ContentUnavailableView(snapshot?.source == "tmux" ? "等待对话记录" : "开始对话", systemImage: "bubble.left.and.bubble.right", description: Text(snapshot?.source == "tmux" ? "选择此窗口的会话记录后，可在这里查看消息与工具结果。" : "向 \(session.displayName) 描述你要完成的任务。"))
                        }
                        ForEach(snapshot?.messages ?? []) { message in MessageCard(message: message, agent: session.displayName).id(message.id) }
                        ForEach(snapshot?.approvals ?? []) { approval in
                            ApprovalView(approval: approval, disabled: sending) { approved, value, answers in
                                Task { await apply(ChatAction(action: "approval", text: value, requestID: approval.id, approved: approved, answers: answers)) }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding()
                }
                .onChange(of: snapshot?.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                if snapshot?.commands.isEmpty == false {
                    Button { commands = true } label: { Image(systemName: "command") }.accessibilityLabel("可用命令")
                }
                TextField("发送给 \(session.displayName)", text: $draft, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder)
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .accessibilityLabel("发送消息")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || !canSend)
            }.padding()
        }
        .navigationTitle(session.displayName).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $models) { modelPanel }
        .sheet(isPresented: $commands) { commandPanel }
        .sheet(isPresented: $conversations) { conversationPanel }
        .confirmationDialog("停止当前任务？", isPresented: $confirmStop) {
            Button("停止任务", role: .destructive) { Task { await apply(ChatAction(action: "abort")) } }
        } message: { Text("保留 Agent 会话及已有对话。") }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await refresh(); connectionError = nil; try await Task.sleep(for: .seconds(1)) }
                catch {
                    if Task.isCancelled { return }
                    connectionError = error.localizedDescription
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }
    private var modelPanel: some View {
        NavigationStack {
            List(snapshot?.models ?? [], id: \.key) { model in
                Button {
                    models = false
                    Task { await apply(ChatAction(action: "model", model: model.id, provider: model.provider)) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name.isEmpty ? model.id : model.name)
                        Text(model.provider.isEmpty ? model.id : model.provider + " / " + model.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("选择模型").toolbar { Button("关闭") { models = false } }
        }
    }
    private var commandPanel: some View {
        NavigationStack {
            List(snapshot?.commands ?? []) { command in
                Button {
                    commands = false
                    if (session.command == "pi" && ["new", "compact"].contains(command.name)) || (session.command == "codex" && command.name == "compact") {
                        Task { await apply(ChatAction(action: "command", text: command.name)) }
                    } else { draft = "/" + command.name + " " }
                } label: {
                    VStack(alignment: .leading) {
                        Text("/" + command.name)
                        Text(command.description).font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(snapshot?.busy == true)
            }.navigationTitle("可用命令").toolbar { Button("关闭") { commands = false } }
        }
    }
    private var conversationPanel: some View {
        NavigationStack {
            List {
                Text("请选择这个 Mac 窗口当前使用的记录。选择只改变展示内容，不会重启或切换 Mac 上的 Agent。").font(.caption).foregroundStyle(.secondary)
                ForEach(snapshot?.conversations ?? []) { conversation in
                    Button {
                        conversations = false
                        Task { await apply(ChatAction(action: "select_conversation", conversationID: conversation.id)) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(conversation.date, style: .date) + Text(" ") + Text(conversation.date, style: .time)
                            Text(conversation.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if snapshot?.conversationID == conversation.id { Label("当前记录", systemImage: "checkmark") }
                        }
                    }
                }
            }.navigationTitle("对话记录").toolbar { Button("关闭") { conversations = false } }
        }
    }
    func refresh() async throws {
        let next: ChatSnapshot = try await client.get(session.mode == "structured" ? base : base + "/chat")
        if let expected = session.agentPID, next.agentPID != expected {
            throw NSError(domain: "AgentMux", code: 409, userInfo: [NSLocalizedDescriptionKey: "Mac 上的 Agent 已更换，请返回会话列表重新打开。"])
        }
        snapshot = next
    }
    func transmit(_ action: ChatAction) async throws {
        var action = action; action.agentPID = session.agentPID
        try await client.send(base + "/actions", value: action)
    }
    func apply(_ action: ChatAction) async {
        guard !sending else { return }
        sending = true; defer { sending = false }
        await client.perform { try await transmit(action); try await refresh() }
    }
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "/model", snapshot?.models.isEmpty == false { models = true; return }
        sending = true
        Task {
            await client.perform {
                if session.mode == "structured" && ["/compact", "/new"].contains(text) && (session.command == "pi" || (session.command == "codex" && text == "/compact")) {
                    try await transmit(ChatAction(action: "command", text: String(text.dropFirst())))
                } else { try await transmit(ChatAction(action: "message", text: text, requestID: pendingID)) }
                draft = ""; pendingID = UUID().uuidString; try await refresh()
            }
            sending = false
        }
    }
}
struct MessageCard: View {
    let message: ChatMessage
    let agent: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message.role == "user" ? "你" : message.role == "tool" ? "工具" : message.role == "assistant" ? agent : "会话动态", systemImage: message.role == "user" ? "person.crop.circle" : message.role == "tool" ? "wrench.and.screwdriver" : "sparkles")
                .font(.caption.bold()).foregroundStyle(.secondary)
            if let tool = message.tool {
                HStack {
                    Text(tool.name).font(.subheadline.bold())
                    Spacer()
                    Label(tool.status == "running" ? "执行中" : tool.status == "error" ? "失败" : "已完成", systemImage: tool.status == "running" ? "clock" : tool.status == "error" ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(tool.status == "error" ? .orange : .secondary)
                }
                DisclosureGroup("查看详情") {
                    VStack(alignment: .leading, spacing: 10) {
                        if !tool.input.isEmpty { Text("输入").font(.caption.bold()); Text(tool.input).font(.caption.monospaced()) }
                        if !tool.output.isEmpty { Text("结果").font(.caption.bold()); Text(tool.output).font(.caption.monospaced()) }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.font(.caption)
            } else if message.role == "tool" {
                DisclosureGroup("查看工具详情") { Text(message.text).font(.caption.monospaced()).textSelection(.enabled) }
            } else {
                Text(.init(message.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == "user" ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
struct ApprovalView: View {
    let approval: AgentApproval
    let disabled: Bool
    let reply: (Bool, String, [String: [String]]) -> Void
    @State private var input = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.title, systemImage: "hand.raised.fill").font(.headline)
            if approval.kind != "questions" { Text(approval.detail).font(.caption).textSelection(.enabled) }
            if approval.kind == "questions" {
                QuestionForm(questions: approval.questions ?? []) { reply(true, "", $0) }
            } else if approval.kind == "unsupported" {
                Text("此请求暂不支持，请在 Mac 上处理或停止当前任务。").foregroundStyle(.orange)
            } else if approval.kind == "select" {
                ForEach(approval.options, id: \.self) { option in Button(option) { reply(true, option, [:]) } }
            } else if ["input", "editor"].contains(approval.kind) {
                TextField("回复", text: $input, axis: .vertical)
                Button("提交") { reply(true, input, [:]) }
            } else { Button("允许一次") { reply(true, "", [:]) }.buttonStyle(.borderedProminent) }
            if approval.kind != "unsupported" { Button("拒绝 / 取消", role: .destructive) { reply(false, "", [:]) } }
        }.padding().background(Color.orange.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 16)).disabled(disabled)
    }
}

struct QuestionForm: View {
    let questions: [AgentQuestion]
    let submit: ([String: [String]]) -> Void
    @State private var selected: [String: [String]] = [:]
    @State private var custom: [String: String] = [:]
    private var answers: [String: [String]] {
        questions.reduce(into: [:]) { result, question in
            let value = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            result[question.id] = value.isEmpty ? (selected[question.id] ?? []) : [value]
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.prompt).font(.subheadline.bold())
                    ForEach(question.options, id: \.label) { option in
                        Button {
                            custom[question.id] = ""
                            var values = selected[question.id] ?? []
                            if question.multiple {
                                if values.contains(option.label) { values.removeAll { $0 == option.label } }
                                else { values.append(option.label) }
                            } else { values = [option.label] }
                            selected[question.id] = values
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: (selected[question.id] ?? []).contains(option.label) && (custom[question.id] ?? "").isEmpty ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.label)
                                    if !option.description.isEmpty { Text(option.description).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered)
                    }
                    if question.other {
                        let binding = Binding(get: { custom[question.id] ?? "" }, set: { custom[question.id] = $0 })
                        if question.secret { SecureField("输入回复", text: binding).textFieldStyle(.roundedBorder) }
                        else { TextField("其他回复", text: binding, axis: .vertical).textFieldStyle(.roundedBorder) }
                    }
                }
            }
            Button("提交回答") { submit(answers) }.buttonStyle(.borderedProminent)
                .disabled(questions.isEmpty || answers.values.contains(where: \.isEmpty))
        }
    }
}
