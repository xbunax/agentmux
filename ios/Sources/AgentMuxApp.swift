import SwiftUI
import Security
import UniformTypeIdentifiers

struct AgentSession: Codable, Identifiable {
    let id: String
    let name: String
    let directory: String
    let command: String
    let mode: String
    var windowID: String?
    var windowName: String?
    var sessionName: String?
    var agentPID: UInt32?
    var nativeAgentPID: UInt32?
    var nativePaneID: String?
    var displayName: String { command == "claude" ? "Claude Code" : command == "codex" ? "Codex" : "Pi" }
    enum CodingKeys: String, CodingKey {
        case id, name, directory, command, mode
        case windowID = "window_id", windowName = "window_name", sessionName = "session_name", agentPID = "agent_pid"
        case nativeAgentPID = "native_agent_pid", nativePaneID = "native_pane_id"
    }
}
struct Agents: Codable { var codex: String; var claude: String; var pi: String }
struct ServiceConfig: Codable {
    var revision: UInt64
    var roots: [String]
    var defaultDirectory: String
    var agents: Agents
    enum CodingKeys: String, CodingKey {
        case revision, roots, agents
        case defaultDirectory = "default_directory"
    }
}
struct FileEntry: Codable, Identifiable {
    var id: String { name }
    let name: String
    let directory: Bool
    let size: UInt64
}
enum Keychain {
    static let service = "dev.agentmux.connection"
    static func load(account: String = "token") -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String, account: String = "token") throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotCreateFile) }
        } else if status != errSecSuccess { throw URLError(.cannotWriteToFile) }
    }
}
@MainActor final class Client: ObservableObject {
    @Published var paired: PairedMac? = try? JSONDecoder().decode(PairedMac.self, from: Data(Keychain.load(account: "paired-mac").utf8))
    @Published var error: String?
    let ssh = SSHTransport()
    func connectSSH(host: String, port: Int, username: String, hostKey: String, login: SSHLogin) async throws {
        let mac = try await ssh.connectSSH(host: host, port: port, username: username, hostKey: hostKey, login: login, deviceName: "AgentMux iPhone")
        do {
            try Task.checkCancellation()
            try Keychain.save(String(decoding: JSONEncoder().encode(mac), as: UTF8.self), account: "paired-mac")
        } catch {
            _ = try? await ssh.request(profile: mac, path: "/v1/devices/\(mac.deviceID)", method: "DELETE", token: mac.credential, body: nil)
            await ssh.disconnect()
            throw error
        }
        paired = mac
        error = nil
    }
    func forget() async {
        await perform {
            if let paired { _ = try await request("/v1/devices/\(paired.deviceID)", method: "DELETE") }
            try Keychain.save("", account: "paired-mac")
            await ssh.disconnect(); paired = nil
        }
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        guard let paired else { throw NSError(domain: "AgentMux", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先通过 SSH 连接 Mac"]) }
        var url = URLComponents(); url.path = path; url.queryItems = query.isEmpty ? nil : query
        guard let uri = url.string else { throw URLError(.badURL) }
        let response = try await ssh.request(profile: paired, path: uri, method: method, token: paired.credential, body: body)
        guard (200..<300).contains(response.status) else {
            throw NSError(domain: "AgentMux", code: response.status, userInfo: [NSLocalizedDescriptionKey: String(decoding: response.data, as: UTF8.self)])
        }
        return response.data
    }
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: await request(path, query: query))
    }
    func send<T: Encodable>(_ path: String, method: String = "POST", value: T) async throws {
        _ = try await request(path, method: method, body: JSONEncoder().encode(value))
    }
    func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
@main struct AgentMuxApp: App {
    @StateObject var client = Client()
    var body: some Scene {
        WindowGroup {
            TabView {
                SessionList().tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right") }
                FileBrowser().tabItem { Label("文件", systemImage: "folder") }
                SettingsView().tabItem { Label("设置", systemImage: "gearshape") }
            }
            .environmentObject(client)
            .alert("操作失败", isPresented: Binding(get: { client.error != nil }, set: { if !$0 { client.error = nil } })) {
                Button("确定") { client.error = nil }
            } message: { Text(client.error ?? "") }
        }
    }
}
struct AgentWindow: Identifiable { let id: String; let panes: [AgentSession] }
struct SessionList: View {
    @EnvironmentObject var client: Client
    @Environment(\.scenePhase) var phase
    @State private var sessions: [AgentSession] = []
    @State private var creating = false
    private var windows: [AgentWindow] {
        Dictionary(grouping: sessions.filter { $0.mode == "tmux" }, by: { $0.windowID ?? $0.id })
            .map { AgentWindow(id: $0.key, panes: $0.value) }
            .sorted { ($0.panes.first?.name ?? "") < ($1.panes.first?.name ?? "") }
    }
    var body: some View {
        NavigationStack {
            List {
                Section { PairingStatus() }
                if sessions.isEmpty, client.paired != nil {
                    ContentUnavailableView("暂无运行中的 Agent", systemImage: "bubble.left.and.bubble.right", description: Text("在 Mac 的 tmux 窗口中启动 Codex、Claude Code 或 Pi，或点 + 开始新对话。"))
                }
                let plugins = sessions.filter { $0.mode == "plugin" }
                if !plugins.isEmpty {
                    Section("插件连接 · 原有会话") {
                        ForEach(plugins) { session in
                            NavigationLink { ChatView(session: session) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(session.displayName, systemImage: "puzzlepiece.extension").font(.headline)
                                    Text(session.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
                if !windows.isEmpty {
                    Section("Mac 上的 Agent") {
                        ForEach(windows) { window in
                            let panes = window.panes
                            if let first = panes.first {
                                NavigationLink {
                                    if panes.count == 1 { ChatView(session: first) }
                                    else {
                                        List(Array(panes.enumerated()), id: \.element.id) { index, pane in
                                            NavigationLink("\(pane.displayName) · \(index + 1)") { ChatView(session: pane) }
                                        }.navigationTitle(first.windowName ?? first.name)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(first.windowName ?? first.name).font(.headline)
                                        Text(panes.map(\.displayName).joined(separator: " · ")).font(.subheadline)
                                        Text((first.sessionName ?? "") + " · " + first.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
                let managed = sessions.filter { $0.mode == "structured" }
                if !managed.isEmpty {
                    Section("App 中的对话") {
                        ForEach(managed) { session in
                            NavigationLink { ChatView(session: session) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(session.displayName, systemImage: "sparkles").font(.headline)
                                    Text(session.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .navigationTitle("AgentMux")
            .toolbar { Button { creating = true } label: { Image(systemName: "plus") }.disabled(client.paired == nil) }
            .refreshable { await refresh() }
            .task(id: "\(client.paired?.deviceID ?? "")-\(phase)") {
                guard phase == .active, client.paired != nil else { sessions = []; return }
                while !Task.isCancelled { await refresh(); try? await Task.sleep(for: .seconds(5)) }
            }
            .sheet(isPresented: $creating, onDismiss: { Task { await refresh() } }) { CreateSession() }
        }
    }
    func refresh() async {
        await client.perform {
            let managed: [AgentSession] = try await client.get("/v1/managed")
            let plugins: [AgentSession] = (try? await client.get("/v1/plugins")) ?? []
            let discovered: [AgentSession] = try await client.get("/v1/sessions")
            let remaining = discovered.filter { pane in
                !plugins.contains { $0.nativeAgentPID == pane.agentPID && $0.nativePaneID == pane.id }
            }
            sessions = plugins + managed + remaining
        }
    }
}
struct CreateSession: View {
    @EnvironmentObject var client: Client
    @Environment(\.dismiss) var dismiss
    @State private var agent = "codex"
    @State private var directory = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Picker("Agent", selection: $agent) { Text("Codex").tag("codex"); Text("Claude Code").tag("claude"); Text("Pi").tag("pi") }
                TextField("Mac 上的绝对目录", text: $directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("目录必须已存在且处于授权范围。使用 Mac 已配置的 Agent 登录状态。").font(.caption)
                Button("创建") {
                    busy = true
                    Task {
                        await client.perform { try await client.send("/v1/managed", value: ["agent": agent, "directory": directory]); dismiss() }
                        busy = false
                    }
                }.disabled(busy || directory.isEmpty)
            }
            .navigationTitle("新建 Agent")
            .toolbar { Button("取消") { dismiss() } }
            .task { await client.perform { let config: ServiceConfig = try await client.get("/v1/settings"); directory = config.defaultDirectory } }
        }
    }
}
struct SettingsView: View {
    @EnvironmentObject var client: Client
    @State private var config: ServiceConfig?
    @State private var directory = ""
    @State private var roots = ""
    @State private var saved = false
    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    PairingStatus()
                }
                Section("Mac 服务") {
                    Button("读取服务配置") { Task { await load() } }
                    if let config {
                        Text("配置版本 \(config.revision)")
                        TextField("默认目录", text: $directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("授权目录，每行一个", text: $roots, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                        LabeledContent("Codex", value: config.agents.codex)
                        LabeledContent("Claude", value: config.agents.claude)
                        LabeledContent("Pi", value: config.agents.pi)
                        Text("只能缩小 Mac 启动时批准的目录范围；可执行路径仅允许本机修改。配置不改变现有会话。").font(.caption)
                        Button("应用配置") {
                            Task { await client.perform {
                                var updated = config; updated.defaultDirectory = directory
                                updated.roots = roots.split(separator: "\n").map(String.init)
                                try await client.send("/v1/settings", method: "PUT", value: updated)
                                await load(); saved = true
                            } }
                        }
                    }
                }
            }.navigationTitle("设置").alert("配置已应用", isPresented: $saved) { Button("确定", role: .cancel) {} }
        }
    }
    func load() async {
        await client.perform {
            let loaded: ServiceConfig = try await client.get("/v1/settings")
            config = loaded
            directory = loaded.defaultDirectory
            roots = loaded.roots.joined(separator: "\n")
        }
    }
}
struct FileBrowser: View {
    @EnvironmentObject var client: Client
    @State private var path = ""
    @State private var entries: [FileEntry] = []
    @State private var importing = false
    @State private var downloaded: URL?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            List {
                TextField("Mac 目录", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("浏览") { Task { await load() } }
                Button("上传文件") { importing = true }.disabled(path.isEmpty || busy)
                Text("单文件上限 8 MiB，不覆盖已有文件。下载后可通过系统分享保存。").font(.caption).foregroundStyle(.secondary)
                if let downloaded { ShareLink("分享 / 保存已下载文件", item: downloaded) }
                ForEach(entries) { entry in
                    Button {
                        if entry.directory { path = (path as NSString).appendingPathComponent(entry.name); Task { await load() } }
                        else { Task { await download(entry) } }
                    } label: {
                        Label(entry.name, systemImage: entry.directory ? "folder" : "arrow.down.doc")
                    }.disabled(busy)
                }
            }.navigationTitle("文件")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                Task {
                    await client.perform {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 8 * 1024 * 1024 else { throw NSError(domain: "AgentMux", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件超过 8 MiB"]) }
                        busy = true; defer { busy = false }
                        let data = try Data(contentsOf: url)
                        let destination = (path as NSString).appendingPathComponent(url.lastPathComponent)
                        _ = try await client.request(
                            "/v1/file", method: "PUT", body: data,
                            query: [URLQueryItem(name: "path", value: destination)]
                        )
                        await load()
                    }
                }
            }
        }
    }
    func load() async { await client.perform { entries = try await client.get("/v1/files", query: [URLQueryItem(name: "path", value: path)]) } }
    func download(_ entry: FileEntry) async {
        busy = true; defer { busy = false }
        await client.perform {
            let data = try await client.request("/v1/file", query: [URLQueryItem(name: "path", value: (path as NSString).appendingPathComponent(entry.name))])
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(entry.name)
            try data.write(to: file, options: .atomic); downloaded = file
        }
    }
}
