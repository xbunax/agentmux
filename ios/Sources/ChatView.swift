import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ToolDetail: Decodable {
    let name: String; let input: String; let output: String; let status: String
}
struct ChatMessage: Decodable, Identifiable {
    let id: String; let role: String; let text: String; let tool: ToolDetail?
    var attachments: [RemoteAttachment]? = nil
}
struct AgentModel: Decodable, Identifiable {
    let id: String; let name: String; let provider: String
    var reasoningEfforts: [ReasoningChoice]? = nil; var defaultEffort: String? = nil
    var key: String { provider + "/" + id }
    enum CodingKeys: String, CodingKey { case id, name, provider; case reasoningEfforts = "reasoning_efforts", defaultEffort = "default_effort" }
}
struct ReasoningChoice: Decodable, Identifiable { let id: String; let name: String }
struct SlashCommand: Decodable, Identifiable { var id: String { name }; let name: String; let description: String; let kind: String? }
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
struct AgentMenuChoice: Decodable, Identifiable { let id: Int; let label: String; let selected: Bool }
struct AgentMenuControl: Decodable, Identifiable { let id: String; let label: String }
struct AgentMenu: Decodable, Identifiable {
    let id: String; let title: String; let detail: String; let options: [AgentMenuChoice]; let route: String?
    let actions: [AgentMenuControl]?; let searchable: Bool?; let query: String?; let visibleOnly: Bool?
    enum CodingKeys: String, CodingKey { case id, title, detail, options, route, actions, searchable, query; case visibleOnly = "visible_only" }
}
struct ChatSnapshot: Decodable {
    let messages: [ChatMessage]; let models: [AgentModel]; let commands: [SlashCommand]
    let model: String; let busy: Bool; let alive: Bool; let approvals: [AgentApproval]
    let error: String?; let revision: UInt64
    let capabilities: ChatCapabilities?; let notice: String?; let conversations: [Conversation]?
    let agentPID: UInt32?; let conversationID: String?; let source: String?; let interaction: AgentMenu?; let abortRoute: String?
    enum CodingKeys: String, CodingKey {
        case messages, models, commands, model, busy, alive, approvals, error, revision, capabilities, notice, conversations, source, interaction
        case agentPID = "agent_pid", conversationID = "conversation_id", abortRoute = "abort_route"
    }
}
struct ChatAction: Encodable {
    let action: String
    var text = ""; var model = ""; var provider = ""; var requestID = ""; var approved = false
    var agentPID: UInt32?; var conversationID = ""; var answers: [String: [String]] = [:]
    var menuID = ""; var choice: Int?; var route: String?; var attachments: [String] = []
    var controlID = ""
    var effort = ""
    enum CodingKeys: String, CodingKey {
        case action, text, model, provider, approved, answers, choice, route, attachments, effort
        case requestID = "request_id", agentPID = "agent_pid", conversationID = "conversation_id", menuID = "menu_id"
        case controlID = "control_id"
    }
}

struct ChatDraftState {
    var text = ""
    var files: [PendingAttachment] = []
    var pendingID = UUID().uuidString
    var attempted: String?
    var echoes: [LocalEcho] = []
}
struct LocalEcho { let message: ChatMessage; let historyCount: Int }

struct ChatView: View {
    @EnvironmentObject var client: Client
    @Environment(\.scenePhase) var phase
    @State private var session: AgentSession
    let availableSessions: [AgentSession]
    @State private var snapshot: ChatSnapshot?
    @State private var draft = ""
    @State private var files: [PendingAttachment] = []
    @State private var echoes: [LocalEcho] = []
    @State private var sending = false
    @State private var picking = false
    @State private var models = false
    @State private var commands = false
    @State private var conversations = false
    @State private var sessionPicker = false
    @State private var info = false
    @State private var confirmStop = false
    @State private var importing = false
    @State private var photoPicker = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var modelSearch = ""
    @State private var selectedModel: AgentModel?
    @State private var commandSearch = ""
    @State private var pendingID = UUID().uuidString
    @State private var attemptedText: String?
    @State private var connectionError: String?
    @State private var nearBottom = true
    @FocusState private var composing: Bool

    init(session: AgentSession, availableSessions: [AgentSession] = []) {
        _session = State(initialValue: session)
        self.availableSessions = availableSessions
    }
    private var base: String {
        let collection = session.mode == "structured" ? "managed" : session.mode == "plugin" ? "plugins" : "sessions"
        return "/v1/\(collection)/\(session.id)"
    }
    private var canSend: Bool { snapshot?.alive == true && (snapshot?.capabilities?.message ?? (snapshot?.busy == false)) && connectionError == nil }
    private var status: String {
        if connectionError != nil { return "正在重新连接" }
        if snapshot == nil { return "正在连接…" }
        if snapshot?.alive == false { return "会话已结束" }
        if snapshot?.interaction != nil || snapshot?.approvals.isEmpty == false { return "等待你的确认" }
        if snapshot?.busy == true { return "正在工作…" }
        return canSend ? "可以发送消息" : "等待输入就绪"
    }
    private var matchingCommands: [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: { $0.isWhitespace }) else { return [] }
        let prefix = String(draft.dropFirst()).lowercased()
        return (snapshot?.commands ?? []).filter { $0.name.lowercased().hasPrefix(prefix) }
    }
    private var messages: [ChatMessage] {
        let history = snapshot?.messages ?? []
        return history + echoes.filter { echo in
            !history.contains { $0.id == echo.message.id } && history.filter { matches($0, echo.message) }.count <= echo.historyCount
        }.map(\.message)
    }
    private func matches(_ remote: ChatMessage, _ local: ChatMessage) -> Bool {
        remote.role == "user" && AttachmentContent.parse(remote.text).text == local.text &&
            Set((remote.attachments ?? AttachmentContent.parse(remote.text).files).map(\.id)) == Set((local.attachments ?? []).map(\.id))
    }
    private var scrollRevision: String {
        "\(messages.count):\(messages.last?.id ?? ""):\(messages.last?.text.count ?? 0):\(messages.last?.tool?.output.count ?? 0):\(snapshot?.interaction?.id ?? ""):\(snapshot?.approvals.count ?? 0)"
    }
    var body: some View {
        timeline
            .background(AppTheme.chat)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle(session.displayName).navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbarBackground(AppTheme.surface, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { sessionPicker = true } label: {
                        HStack(spacing: 9) {
                            AgentAvatar(command: session.command, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) { Text(session.displayName).font(.subheadline.weight(.semibold)); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                                Text(status).font(.caption2).foregroundStyle(canSend ? AppTheme.accent : AppTheme.secondary)
                            }
                        }.foregroundStyle(AppTheme.text)
                    }.disabled(sending || picking).accessibilityLabel("\(session.displayName)，\(status)，切换会话")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { info = true } label: { Label("会话详情", systemImage: "info.circle") }
                        if snapshot?.commands.isEmpty == false { Button { commands = true } label: { Label("命令", systemImage: "command") } }
                        if snapshot?.models.isEmpty == false { Button { models = true } label: { Label("选择模型", systemImage: "slider.horizontal.3") }.disabled(snapshot?.busy == true) }
                        if snapshot?.conversations?.isEmpty == false { Button { conversations = true } label: { Label("对话记录", systemImage: "clock.arrow.circlepath") } }
                        if snapshot?.capabilities?.abort ?? (snapshot?.busy == true) {
                            Button(role: .destructive) { confirmStop = true } label: { Label("停止任务", systemImage: "stop.circle") }
                        }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }.accessibilityLabel("会话操作")
                }
            }
            .sheet(isPresented: $models, onDismiss: { selectedModel = nil; modelSearch = "" }) { modelPanel }
            .sheet(isPresented: $commands) { commandPanel }
            .sheet(isPresented: $conversations) { conversationPanel }
            .sheet(isPresented: $sessionPicker) { sessionPanel }
            .sheet(isPresented: $info) { infoPanel }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                Task { await importFiles(result) }
            }
            .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: max(1, 6 - files.count), matching: .images)
            .onChange(of: photos) { _, selected in Task { await importPhotos(selected) } }
            .confirmationDialog("停止当前任务？", isPresented: $confirmStop) {
                Button("停止任务", role: .destructive) { Task { await apply(ChatAction(action: "abort", route: snapshot?.abortRoute)) } }
            } message: { Text("保留 Agent 会话及已有对话。") }
            .onAppear { restoreDraft() }
            .onDisappear { saveDraft() }
            .task(id: "\(phase)-\(session.key)") {
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
    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(session.projectName + (session.sessionName.map { " · " + $0 } ?? ""))
                        .font(.caption).foregroundStyle(AppTheme.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(AppTheme.surface.opacity(0.7), in: Capsule()).frame(maxWidth: .infinity).padding(.vertical, 14)
                    if let error = connectionError ?? snapshot?.error {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "wifi.exclamationmark")
                            Text(error).font(.caption).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }.foregroundStyle(AppTheme.warning).padding(12).appPanel()
                    }
                    if snapshot != nil && messages.isEmpty && snapshot?.interaction == nil {
                        VStack(spacing: 18) {
                            EmptyState(symbol: "bubble.left.and.text.bubble.right", title: "与 \(session.displayName) 对话", detail: "消息会发往 Mac 上的当前会话。\n文字、图片和文件，都可以从下方发送。")
                            if snapshot?.conversations?.isEmpty == false {
                                Button { conversations = true } label: { Label("载入已有对话记录", systemImage: "clock.arrow.circlepath") }
                                    .font(.subheadline).frame(minHeight: 44)
                            }
                        }.padding(.bottom, 20)
                    }
                    ForEach(messages) { message in MessageCard(message: message, agent: session.displayName, command: session.command).id(message.id) }
                    if snapshot?.busy == true {
                        HStack(spacing: 9) { ProgressView().controlSize(.small); Text("\(session.displayName) 正在工作…").font(.caption).foregroundStyle(AppTheme.secondary) }.padding(12)
                    }
                    if let menu = snapshot?.interaction {
                        AgentMenuCard(menu: menu, disabled: sending) { action, choice, control, text in
                            Task { await apply(ChatAction(action: action, text: text, menuID: menu.id, choice: choice, route: menu.route, controlID: control)) }
                        }
                    }
                    ForEach(snapshot?.approvals ?? []) { approval in
                        ApprovalView(approval: approval, disabled: sending) { approved, value, answers in
                            Task { await apply(ChatAction(action: "approval", text: value, requestID: approval.id, approved: approved, answers: answers)) }
                        }
                    }
                    Color.clear.frame(height: 8).id("bottom").onAppear { nearBottom = true }.onDisappear { nearBottom = false }
                }.padding(.horizontal, 12).frame(maxWidth: 780).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
                .onChange(of: scrollRevision) { _, _ in if nearBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                .overlay(alignment: .bottomTrailing) {
                    if !nearBottom {
                        Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                            Image(systemName: "arrow.down").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                                .background(AppTheme.surface, in: Circle()).overlay(Circle().stroke(AppTheme.line, lineWidth: 0.5))
                        }.padding(14).accessibilityLabel("回到最新消息")
                    }
                }
        }
    }
    private var composer: some View {
        VStack(spacing: 0) {
            if !matchingCommands.isEmpty { commandCompletions }
            if !files.isEmpty {
                PendingAttachmentsStrip(files: files, disabled: sending) { id in files.removeAll { $0.id == id }; saveDraft() }
            }
            if !canSend, snapshot != nil {
                Button { info = true } label: { Label(status, systemImage: snapshot?.interaction == nil ? "info.circle" : "hand.tap").font(.caption).foregroundStyle(AppTheme.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    .padding(.horizontal, 18).padding(.top, 9).accessibilityHint("查看输入状态说明")
            }
            HStack(alignment: .bottom, spacing: 7) {
                Menu {
                    Button { photoPicker = true } label: { Label("照片图库", systemImage: "photo.on.rectangle") }
                    Button { importing = true } label: { Label("文件", systemImage: "doc") }
                } label: { Image(systemName: "paperclip").font(.system(size: 22)).frame(width: 44, height: 46).foregroundStyle(AppTheme.secondary) }
                    .disabled(sending || picking || files.count >= 6).accessibilityLabel("添加照片或文件")
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(files.isEmpty ? "消息" : "添加说明", text: $draft, axis: .vertical)
                        .font(.body).lineLimit(1...6).focused($composing).padding(.vertical, 12).padding(.leading, 15)
                    if snapshot?.commands.isEmpty == false {
                        Button {
                            if draft.isEmpty { draft = "/"; composing = true }
                            else if draft == "/" { draft = "" }
                            else { commands = true }
                        } label: { Image(systemName: "command").font(.system(size: 18)).frame(width: 42, height: 46).foregroundStyle(AppTheme.secondary) }
                            .accessibilityLabel("Agent 命令")
                    }
                }.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(AppTheme.line.opacity(0.5), lineWidth: 0.5))
                Button { send() } label: {
                    Group {
                        if sending || picking { ProgressView().tint(AppTheme.background) }
                        else { Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)) }
                    }.frame(width: 46, height: 46)
                        .foregroundStyle(AppTheme.background).background(AppTheme.accent, in: Circle())
                }.accessibilityLabel(sending ? "正在发送" : "发送消息")
                    .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty) || sending || picking || !canSend)
                    .opacity((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty) || !canSend ? 0.4 : 1)
            }.padding(.horizontal, 8).padding(.vertical, 9)
        }.background(.ultraThinMaterial)
    }
    private var commandCompletions: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(matchingCommands) { command in commandRow(command) }
            }
        }.frame(maxHeight: 230).background(AppTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(AppTheme.line).frame(height: 0.5) }
    }
    private func commandRow(_ command: SlashCommand) -> some View {
        Button { draft = "/" + command.name + " "; composing = true; commands = false } label: {
            HStack(spacing: 13) {
                Text("/").font(.title3.monospaced().weight(.semibold)).foregroundStyle(AppTheme.accent)
                    .frame(width: 36, height: 36).background(AppTheme.accent.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("/" + command.name).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.text)
                    Text(command.description).font(.caption).foregroundStyle(AppTheme.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(AppTheme.secondary)
            }.padding(.horizontal, 17).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(sending)
    }
    private var modelPanel: some View {
        NavigationStack {
            List {
                if let selectedModel {
                    Section {
                        Button { self.selectedModel = nil } label: { Label("重新选择模型", systemImage: "chevron.left") }
                        Text(selectedModel.name.isEmpty ? selectedModel.id : selectedModel.name).font(.headline)
                    }.listRowBackground(AppTheme.surface)
                    ForEach(selectedModel.reasoningEfforts ?? []) { effort in
                        Button {
                            models = false; self.selectedModel = nil
                            Task { await apply(ChatAction(action: "model", model: selectedModel.id, provider: selectedModel.provider, effort: effort.id)) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(effort.id).font(.body.weight(.semibold))
                                Text(effort.name).font(.caption).foregroundStyle(AppTheme.secondary)
                                if effort.id == selectedModel.defaultEffort { Text("Agent 默认值").font(.caption2).foregroundStyle(AppTheme.accent) }
                            }.padding(.vertical, 6)
                        }.listRowBackground(AppTheme.surface).disabled(sending)
                    }
                } else {
                    ForEach((snapshot?.models ?? []).filter { modelSearch.isEmpty || ($0.name + " " + $0.id + " " + $0.provider).localizedCaseInsensitiveContains(modelSearch) }, id: \.key) { model in
                        Button {
                            if model.reasoningEfforts?.isEmpty == false { selectedModel = model }
                            else {
                                models = false
                                Task { await apply(ChatAction(action: "model", model: model.id, provider: model.provider)) }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: snapshot?.model == model.id ? "checkmark.circle.fill" : "circle").foregroundStyle(AppTheme.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.name.isEmpty ? model.id : model.name).foregroundStyle(AppTheme.text)
                                    Text(model.id).font(.caption).foregroundStyle(AppTheme.secondary)
                                }
                            }.padding(.vertical, 5)
                        }.listRowBackground(AppTheme.surface).disabled(sending || snapshot?.busy == true)
                    }
                }
            }.appList().searchable(text: $modelSearch, prompt: "搜索模型")
                .navigationTitle(selectedModel == nil ? "选择模型" : "选择思考强度").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { models = false; selectedModel = nil } }

        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private var commandPanel: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach((snapshot?.commands ?? []).filter { commandSearch.isEmpty || ($0.name + " " + $0.description).localizedCaseInsensitiveContains(commandSearch) }) { command in commandRow(command) }
                }
            }.background(AppTheme.background).searchable(text: $commandSearch, prompt: "搜索命令")
                .navigationTitle("Agent 命令").navigationBarTitleDisplayMode(.inline).toolbar { Button("完成") { commands = false } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private var conversationPanel: some View {
        NavigationStack {
            List {
                Section { Text("选择要显示的历史记录。发送消息仍操作当前 Agent，不会切换或重建进程。").font(.caption).foregroundStyle(AppTheme.secondary) }.listRowBackground(Color.clear)
                ForEach(snapshot?.conversations ?? []) { conversation in
                    Button {
                        conversations = false
                        Task { await apply(ChatAction(action: "select_conversation", conversationID: conversation.id)) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: snapshot?.conversationID == conversation.id ? "checkmark.circle.fill" : "bubble.left").foregroundStyle(AppTheme.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                (Text(conversation.date, style: .date) + Text(" · ") + Text(conversation.date, style: .time)).font(.subheadline).foregroundStyle(AppTheme.text)
                                Text(conversation.title).font(.caption).foregroundStyle(AppTheme.secondary).lineLimit(2)
                            }
                        }.padding(.vertical, 5)
                    }.listRowBackground(AppTheme.surface).disabled(sending)
                }
            }.appList().navigationTitle("对话记录").navigationBarTitleDisplayMode(.inline).toolbar { Button("完成") { conversations = false } }
        }.presentationDragIndicator(.visible)
    }
    private var sessionPanel: some View {
        NavigationStack {
            List(availableSessions.isEmpty ? [session] : availableSessions) { next in
                Button {
                    guard !sending && !picking else { return }
                    saveDraft(); session = next; snapshot = nil; connectionError = nil; restoreDraft(); sessionPicker = false; nearBottom = true
                } label: {
                    HStack(spacing: 0) {
                        SessionRow(session: next)
                        if next.key == session.key { Image(systemName: "checkmark").foregroundStyle(AppTheme.accent).padding(.trailing) }
                    }
                }.listRowInsets(EdgeInsets()).listRowBackground(AppTheme.surface).disabled(sending || picking)
            }.appList().navigationTitle("切换对话").navigationBarTitleDisplayMode(.inline).toolbar { Button("完成") { sessionPicker = false } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private var infoPanel: some View {
        NavigationStack {
            List {
                Section {
                    HStack { Spacer(); VStack(spacing: 12) { AgentAvatar(command: session.command, size: 76); Text(session.displayName).font(.title2.weight(.semibold)); StatusBadge(title: status) }; Spacer() }.padding(.vertical, 18)
                }.listRowBackground(Color.clear)
                Section("当前会话") {
                    LabeledContent("来源", value: session.sourceName)
                    if let name = session.sessionName { LabeledContent("tmux 会话", value: name) }
                    if let name = session.windowName { LabeledContent("窗口", value: name) }
                    Text(session.directory).font(.subheadline.monospaced()).textSelection(.enabled)
                    if let notice = snapshot?.notice { Text(notice).font(.subheadline).foregroundStyle(AppTheme.secondary) }
                }.listRowBackground(AppTheme.surface)
                Section { Label("通过 SSH 加密连接到 Mac", systemImage: "lock.shield").font(.caption).foregroundStyle(AppTheme.secondary) }.listRowBackground(Color.clear)
            }.appList().navigationTitle("会话详情").navigationBarTitleDisplayMode(.inline).toolbar { Button("完成") { info = false } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func refresh() async throws {
        let expected = session
        let next: ChatSnapshot = try await client.get(session.mode == "structured" ? base : base + "/chat")
        try Task.checkCancellation()
        guard session.key == expected.key else { return }
        if let pid = expected.agentPID, next.agentPID != pid { throw attachmentError("Mac 上的 Agent 已更换，请返回对话列表重新打开。") }
        snapshot = next
    }
    private func transmit(_ value: ChatAction) async throws {
        var action = value; action.agentPID = session.agentPID
        if action.action == "command", action.requestID.isEmpty { action.requestID = UUID().uuidString }
        try await client.send(base + "/actions", value: action)
    }
    private func apply(_ action: ChatAction) async {
        guard !sending else { return }
        sending = true; defer { sending = false }
        await client.perform { try await transmit(action); try await refresh() }
    }
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !sending, !picking, !text.isEmpty || !files.isEmpty else { return }
        if text.hasPrefix("/"), !files.isEmpty { client.error = "Slash 命令请单独发送，或移除附件后再试。"; return }
        if text == "/model", snapshot?.models.isEmpty == false { models = true; return }
        let fingerprint = text + "\n" + files.map(\.id).joined(separator: ",")
        if attemptedText != fingerprint { pendingID = UUID().uuidString; attemptedText = fingerprint }
        sending = true
        Task {
            defer { sending = false; saveDraft() }
            await client.perform {
                for index in files.indices where files[index].uploaded == nil {
                    let file = files[index]
                    let data = try await Task.detached { try Data(contentsOf: file.url) }.value
                    let response = try await client.request("/v1/attachments/" + file.id, method: "PUT", body: data, query: [URLQueryItem(name: "name", value: file.name)])
                    files[index].uploaded = try JSONDecoder().decode(RemoteAttachment.self, from: response)
                    client.attachmentURLs[file.id] = file.url
                }
                let name = text.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                let nativeCommand = text.hasPrefix("/") && snapshot?.commands.contains { $0.name == name && $0.kind == "command" } == true
                if nativeCommand {
                    try await transmit(ChatAction(action: "command", text: String(text.dropFirst()), requestID: pendingID))
                } else if session.mode == "structured" && ["/compact", "/new"].contains(text) && (session.command == "pi" || (session.command == "codex" && text == "/compact")) {
                    try await transmit(ChatAction(action: "command", text: String(text.dropFirst())))
                } else {
                    let route = text.hasPrefix("/") && snapshot?.commands.contains { $0.name == name && $0.kind == "tui" } == true ? "tmux" : nil
                    try await transmit(ChatAction(action: "message", text: text, requestID: pendingID, route: route, attachments: files.map(\.id)))
                    let message = ChatMessage(id: pendingID, role: "user", text: text.isEmpty ? "请查看这些附件。" : text, tool: nil, attachments: files.compactMap(\.uploaded))
                    let historical = (snapshot?.messages ?? []).filter { matches($0, message) }.count
                    let prior = echoes.filter { matches($0.message, message) }.map { $0.historyCount + 1 }.max() ?? 0
                    echoes.append(LocalEcho(message: message, historyCount: max(historical, prior)))
                    if echoes.count > 100 { echoes.removeFirst(echoes.count - 100) }
                }
                draft = ""; files = []; attemptedText = nil; pendingID = UUID().uuidString; nearBottom = true
                try await refresh()
            }
        }
    }
    private func add(_ file: PendingAttachment) throws {
        guard files.count < 6, files.reduce(0, { $0 + $1.size }) + file.size <= 24 * 1024 * 1024 else { throw attachmentError("每条消息最多 6 个附件，总量不能超过 24 MiB。") }
        files.append(file); saveDraft()
    }
    private func importFiles(_ result: Result<[URL], Error>) async {
        picking = true; defer { picking = false }
        await client.perform {
            for url in try result.get() {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else { throw attachmentError("单个文件不能超过 8 MiB。") }
                let file = try await Task.detached { try PendingAttachment.store(data: Data(contentsOf: url), name: url.lastPathComponent) }.value
                try add(file)
            }
        }
    }
    private func importPhotos(_ selected: [PhotosPickerItem]) async {
        guard !selected.isEmpty else { return }
        picking = true; defer { picking = false; photos = [] }
        await client.perform {
            for photo in selected {
                if let data = try await photo.loadTransferable(type: Data.self) {
                    let file = try await Task.detached { try PendingAttachment.photo(data: data) }.value
                    try add(file)
                }
            }
        }
    }
    private func saveDraft() { client.chatDrafts[session.key] = ChatDraftState(text: draft, files: files, pendingID: pendingID, attempted: attemptedText, echoes: echoes) }
    private func restoreDraft() {
        let saved = client.chatDrafts[session.key] ?? ChatDraftState()
        draft = saved.text; files = saved.files; pendingID = saved.pendingID; attemptedText = saved.attempted; echoes = saved.echoes
        #if DEBUG
        if InterfacePreview.enabled {
            if ProcessInfo.processInfo.arguments.contains("--preview-commands") { draft = "/" }
            if ProcessInfo.processInfo.arguments.contains("--preview-attachments") {
                draft = "帮我看看这张界面草图"
                files = InterfacePreview.pendingFiles()
            }
        }
        #endif
    }
}
