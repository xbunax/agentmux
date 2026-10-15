import SwiftUI

struct SessionRow: View {
    @Environment(\.appTheme) private var theme
    let session: AgentSession
    var pinned = false
    var body: some View {
        HStack(spacing: 13) {
            AgentAvatar(command: session.command, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.projectName).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.secondary) }
                    Text(session.sourceName).font(.caption2.weight(.medium)).foregroundStyle(theme.secondary)
                }
                Text(session.displayName)
                    .font(.subheadline).foregroundStyle(theme.secondary).lineLimit(1)
                Text(session.directory).font(.caption).foregroundStyle(theme.secondary.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle)
            }
        }.foregroundStyle(theme.text).padding(.vertical, 12).padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private struct SessionGroup: Identifiable {
    let id: String
    let sessions: [AgentSession]
}

struct SessionList: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var client: Client
    @Environment(\.scenePhase) var phase
    @AppStorage("pinned-sessions") private var pinnedData = "[]"
    @State private var sessions: [AgentSession] = []
    @State private var search = ""
    @State private var provider = "all"
    @State private var creating = false
    @State private var generic = false
    @State private var connectionDetails = false
    @State private var loading = false
    @State private var loadError: String?

    private var pinned: Set<String> { Set((try? JSONDecoder().decode([String].self, from: Data(pinnedData.utf8))) ?? []) }
    private var filtered: [AgentSession] {
        sessions.filter { session in
            (provider == "all" || session.command == provider) &&
            (search.isEmpty || [session.name, session.displayName, session.directory, session.sessionName ?? ""].contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }
    private var groups: [SessionGroup] {
        Dictionary(grouping: filtered.filter { !pinned.contains($0.key) }) { session in
            session.mode == "tmux" ? (session.sessionName ?? "tmux") : session.mode == "plugin" ? "插件连接" : "App 中的对话"
        }.map { SessionGroup(id: $0.key, sessions: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    PairingStatus(manage: false)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    if client.paired != nil {
                        VStack(spacing: 14) {
                            SearchBox(text: $search, placeholder: "搜索 Agent、项目或会话")
                            providerFilters
                        }.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                    }
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                if let loadError {
                    Section {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("连接暂不可用", systemImage: "wifi.exclamationmark").font(.subheadline.weight(.semibold))
                            Text(loadError).font(.caption).lineLimit(3).textSelection(.enabled)
                            Button("重新连接") { Task { await refresh() } }.frame(minHeight: 44)
                        }.foregroundStyle(theme.warning).padding(.vertical, 4)
                    }.listRowBackground(theme.surface)
                }
                if loading && sessions.isEmpty {
                    HStack(spacing: 10) { ProgressView(); Text("正在查找你的 Agent…").font(.subheadline).foregroundStyle(theme.secondary) }
                        .padding(.vertical, 30).frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if client.paired != nil && filtered.isEmpty && loadError == nil {
                    EmptyState(symbol: search.isEmpty && provider == "all" ? "bubble.left.and.bubble.right" : "magnifyingglass",
                               title: sessions.isEmpty ? "你的下一段对话，从这里开始" : "没有匹配的会话",
                               detail: sessions.isEmpty ? "在 Mac 的 tmux 中启动 Agent，\n或轻点右上角，开始新对话。" : "换个关键词，或查看全部 Agent。")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                let favorites = filtered.filter { pinned.contains($0.key) }
                if !favorites.isEmpty { sessionSection("置顶", values: favorites) }
                ForEach(groups) { group in sessionSection(group.id, values: group.sessions) }
            }
            .appList()
            .navigationTitle("会话").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { connectionDetails = true } label: { Image(systemName: "desktopcomputer").font(.title3) }
                        .accessibilityLabel("Mac 连接详情")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("选择任意 tmux pane") { generic = true }
                        Button("新建 Agent 会话") { creating = true }
                    } label: { Image(systemName: "plus").font(.title3) }
                        .disabled(client.paired == nil).accessibilityLabel("新建 Agent 对话")
                }
            }
            .navigationDestination(for: AgentSession.self) { session in SessionDestination(session: session, availableSessions: sessions) }
            .refreshable { await refresh() }
            .task(id: "\(client.paired?.deviceID ?? "")-\(phase)") {
                guard client.paired != nil else { sessions = []; return }
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            .sheet(isPresented: $generic) { GenericPanePicker() }
            .sheet(isPresented: $creating, onDismiss: { Task { await refresh() } }) { CreateSession() }
            .sheet(isPresented: $connectionDetails) {
                NavigationStack {
                    ScrollView { PairingStatus().padding() }.background(AppBackdrop())
                        .navigationTitle("Mac 连接").navigationBarTitleDisplayMode(.inline).toolbar { Button("完成") { connectionDetails = false } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
    }
    private var providerFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["all", "codex", "claude", "pi"], id: \.self) { value in
                    let title = value == "all" ? "全部" : value == "claude" ? "Claude Code" : value == "pi" ? "Pi" : "Codex"
                    Button { withAnimation(.easeInOut(duration: 0.18)) { provider = value } } label: {
                        HStack(spacing: 6) {
                            Text(title).font(.subheadline.weight(provider == value ? .semibold : .regular))
                            if value == "all" { Text("\(sessions.count)").font(.caption.monospacedDigit()) }
                        }.padding(.horizontal, 14).frame(minHeight: 44)
                            .foregroundStyle(provider == value ? theme.accent : theme.secondary)
                            .background(provider == value ? theme.accent.opacity(0.12) : theme.surface, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(provider == value ? .isSelected : [])
                }
            }
        }
    }
    private func sessionSection(_ title: String, values: [AgentSession]) -> some View {
        Section {
            ForEach(values) { session in
                NavigationLink(value: session) { SessionRow(session: session, pinned: pinned.contains(session.key)) }
                    .buttonStyle(.plain).listRowInsets(EdgeInsets())
                    .listRowBackground(theme.surface).listRowSeparatorTint(theme.line)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { togglePin(session) } label: { Label(pinned.contains(session.key) ? "取消置顶" : "置顶", systemImage: "pin") }.tint(theme.accent)
                    }
                    .contextMenu {
                        Button { togglePin(session) } label: { Label(pinned.contains(session.key) ? "取消置顶" : "置顶", systemImage: "pin") }
                    }
            }
        } header: {
            HStack { Text(title); Spacer(); Text("\(values.count)").monospacedDigit() }
                .font(.caption.weight(.semibold)).foregroundStyle(theme.secondary).textCase(nil)
                .padding(.top, 10).padding(.bottom, 5)
        }
    }
    private func togglePin(_ session: AgentSession) {
        var next = pinned
        if next.contains(session.key) { next.remove(session.key) } else { next.insert(session.key) }
        if let data = try? JSONEncoder().encode(next.sorted()) { pinnedData = String(decoding: data, as: UTF8.self) }
    }
    private func refresh() async {
        guard client.paired != nil else { sessions = []; return }
        loading = true; defer { loading = false }
        do {
            let managed: [AgentSession] = try await client.get("/v1/managed")
            let plugins: [AgentSession] = (try? await client.get("/v1/plugins")) ?? []
            let discovered: [AgentSession] = try await client.get("/v1/sessions")
            try Task.checkCancellation()
            let remaining = discovered.filter { pane in !plugins.contains { $0.nativeAgentPID == pane.agentPID && $0.nativePaneID == pane.id } }
            sessions = plugins + managed + remaining
            loadError = nil
        } catch is CancellationError {} catch { loadError = error.localizedDescription }
    }
}

struct CreateSession: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var client: Client
    @Environment(\.dismiss) var dismiss
    @State private var agent = "codex"
    @State private var directory = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("让 Agent 开始工作").font(.title2.weight(.semibold))
                        Text("选择助手和项目，继续在 Mac 上完成任务。").font(.subheadline).foregroundStyle(theme.secondary)
                    }.padding(.vertical, 10)
                }.listRowBackground(Color.clear)
                Section("选择 Agent") {
                    ForEach(["codex", "claude", "pi"], id: \.self) { value in
                        Button { agent = value } label: {
                            HStack(spacing: 12) {
                                AgentAvatar(command: value, size: 38)
                                Text(value == "claude" ? "Claude Code" : value == "pi" ? "Pi" : "Codex").foregroundStyle(theme.text)
                                Spacer()
                                Image(systemName: agent == value ? "checkmark.circle.fill" : "circle").foregroundStyle(agent == value ? theme.accent : theme.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }.listRowBackground(theme.surface)
                Section {
                    TextField("Mac 上的绝对目录", text: $directory).font(.subheadline.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("项目目录") } footer: { Text("使用 Mac 上已登录的 Agent。目录须在授权范围内。") }
                    .listRowBackground(theme.surface)
                Section {
                    Button {
                        busy = true
                        Task {
                            await client.perform { try await client.send("/v1/managed", value: ["agent": agent, "directory": directory]); dismiss() }
                            busy = false
                        }
                    } label: { HStack(spacing: 10) { if busy { ProgressView() }; Text(busy ? "正在创建…" : "开始对话"); Image(systemName: "arrow.up.right") } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy || directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }.appList().navigationTitle("新对话").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .task { await client.perform { let config: ServiceConfig = try await client.get("/v1/settings"); directory = config.defaultDirectory } }
        }.presentationDragIndicator(.visible)
    }
}


struct GenericPanePicker: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var client: Client
    @Environment(\.dismiss) var dismiss
    @State private var panes: [AgentSession] = []
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section { Text("选择终端后即可连接，手机与 Mac 共用同一个会话。未知程序和 shell 也可使用。").font(.subheadline) }
                if let error { Text(error).foregroundStyle(theme.warning) }
                ForEach(panes) { pane in NavigationLink(value: pane) { SessionRow(session: pane) } }
            }.appList().navigationTitle("通用终端")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                .navigationDestination(for: AgentSession.self) { pane in TerminalWorkbench(session: pane, availableSessions: panes) }
                .task { do { panes = try await client.get("/v1/terminal/panes") } catch { self.error = error.localizedDescription } }
        }
    }
}
