import SwiftUI

struct ChatMessage: Decodable, Identifiable { let id: String; let role: String; let text: String }
struct AgentModel: Decodable, Identifiable {
    let id: String; let name: String; let provider: String
    var key: String { provider + "/" + id }
}
struct SlashCommand: Decodable, Identifiable { var id: String { name }; let name: String; let description: String }
struct AgentApproval: Decodable, Identifiable {
    let id: String; let title: String; let detail: String; let options: [String]; let kind: String
}
struct ChatSnapshot: Decodable {
    let messages: [ChatMessage]
    let models: [AgentModel]
    let commands: [SlashCommand]
    let model: String
    let busy: Bool
    let alive: Bool
    let approvals: [AgentApproval]
    let error: String?
    let revision: UInt64
}
struct ChatAction: Encodable {
    let action: String
    var text = ""
    var model = ""
    var provider = ""
    var requestID = ""
    var approved = false
    enum CodingKeys: String, CodingKey {
        case action, text, model, provider, approved
        case requestID = "request_id"
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
    @State private var pendingID = UUID().uuidString
    @State private var connectionError: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(snapshot?.alive == true ? .green : .gray).frame(width: 8, height: 8)
                Text(snapshot?.busy == true ? "正在工作…" : "就绪").font(.caption)
                Spacer()
                Button(snapshot?.model.isEmpty == false ? (snapshot?.model ?? "选择模型") : "选择模型") { models = true }
                    .font(.caption).lineLimit(1).disabled(snapshot?.busy == true || snapshot?.models.isEmpty != false)
            }.padding()
            if let error = connectionError ?? snapshot?.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).padding(.horizontal).textSelection(.enabled)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(snapshot?.messages ?? []) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(label(message.role), systemImage: icon(message.role)).font(.caption.bold()).foregroundStyle(.secondary)
                                if message.role == "tool" {
                                    DisclosureGroup("工具调用 / 结果") { Text(message.text).font(.caption.monospaced()).textSelection(.enabled) }
                                } else {
                                    Text(.init(message.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(12)
                            .background(message.role == "user" ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .id(message.id)
                        }
                        ForEach(snapshot?.approvals ?? []) { approval in
                            ApprovalView(approval: approval) { approved, value in
                                Task { await apply(ChatAction(action: "approval", text: value, requestID: approval.id, approved: approved)) }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding()
                }
                .onChange(of: snapshot?.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom) {
                Button { commands = true } label: { Image(systemName: "command") }.accessibilityLabel("Slash 命令")
                TextField("发送消息或 /命令", text: $draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder)
                if snapshot?.busy == true {
                    Button { Task { await apply(ChatAction(action: "abort")) } } label: { Image(systemName: "stop.circle.fill") }
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || snapshot?.alive != true)
                }
            }.padding()
        }
        .navigationTitle(session.command)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $models) { modelPanel }
        .sheet(isPresented: $commands) { commandPanel }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do {
                    try await refresh(); connectionError = nil
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    if Task.isCancelled { return }
                    connectionError = error.localizedDescription
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }
    private var modelPanel: some View {
        NavigationStack {
            List {
                if session.command == "codex" { Text("模型选择应用于下一次 turn/start，请求失败时会显示 Agent 错误。").font(.caption) }
                ForEach(snapshot?.models ?? [], id: \.key) { model in
                    Button {
                        models = false
                        Task { await apply(ChatAction(action: "model", model: model.id, provider: model.provider)) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(model.name.isEmpty ? model.id : model.name)
                            Text(model.provider + " " + model.id).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("切换模型").toolbar { Button("关闭") { models = false } }
        }
    }
    private var commandPanel: some View {
        NavigationStack {
            List {
                Button("/model — 选择模型") { commands = false; models = true }
                ForEach(snapshot?.commands ?? []) { command in
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
                }
                Text("只显示 Agent 原生协议公开的命令；终端专有命令不会伪装成可用功能。").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Slash 命令").toolbar { Button("关闭") { commands = false } }
        }
    }
    func refresh() async throws { snapshot = try await client.get("/v1/managed/\(session.id)") }
    func apply(_ action: ChatAction) async {
        await client.perform { try await client.send("/v1/managed/\(session.id)/actions", value: action); try await refresh() }
    }
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "/model" { models = true; return }
        sending = true
        Task {
            await client.perform {
                if ["/compact", "/new"].contains(text) && (session.command == "pi" || (session.command == "codex" && text == "/compact")) {
                    try await client.send("/v1/managed/\(session.id)/actions", value: ChatAction(action: "command", text: String(text.dropFirst())))
                } else {
                    try await client.send("/v1/managed/\(session.id)/actions", value: ChatAction(action: "message", text: text, requestID: pendingID))
                }
                draft = ""; pendingID = UUID().uuidString; try await refresh()
            }
            sending = false
        }
    }
    func label(_ role: String) -> String { role == "user" ? "你" : role == "tool" ? "工具" : role == "assistant" ? session.command : "系统" }
    func icon(_ role: String) -> String { role == "user" ? "person" : role == "tool" ? "wrench.and.screwdriver" : "sparkles" }
}
struct ApprovalView: View {
    let approval: AgentApproval
    let reply: (Bool, String) -> Void
    @State private var input = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.title, systemImage: "hand.raised.fill").font(.headline)
            Text(approval.detail).font(.caption).textSelection(.enabled)
            if approval.kind == "unsupported" {
                Text("此 Agent 请求暂不支持；请中断当前任务。不会自动批准。").foregroundStyle(.orange)
            } else if approval.kind == "select" {
                ForEach(approval.options, id: \.self) { option in Button(option) { reply(true, option) } }
            } else if ["input", "editor"].contains(approval.kind) {
                TextField("回复", text: $input, axis: .vertical)
                Button("提交") { reply(true, input) }
            } else {
                Button("允许一次") { reply(true, "") }.buttonStyle(.borderedProminent)
            }
            if approval.kind != "unsupported" { Button("拒绝 / 取消", role: .destructive) { reply(false, "") } }
        }.padding().background(Color.orange.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
