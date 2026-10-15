import SwiftUI
import Security
import UniformTypeIdentifiers

struct AgentSession: Codable, Identifiable {
    let id: String
    let name: String
    let directory: String
    let command: String
    let mode: String
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
    func pair(_ code: PairCode) async throws {
        guard code.version == 1, code.expires > UInt64(Date().timeIntervalSince1970),
              code.port == 9848, code.username == "agentmux", code.ticket.count >= 32,
              !code.host.isEmpty, code.host.count <= 253, code.hostKey.hasPrefix("ssh-ed25519 ") else {
            throw NSError(domain: "AgentMux", code: 1, userInfo: [NSLocalizedDescriptionKey: "二维码无效或已过期，请在 Mac 重新生成"])
        }
        let bootstrap = PairedMac(host: code.host, port: code.port, username: code.username, hostKey: code.hostKey, credential: code.ticket, deviceID: "pending")
        let payload = try JSONEncoder().encode(["ticket": code.ticket, "name": UIDevice.current.name])
        let response = try await ssh.request(profile: bootstrap, path: "/v1/pair/complete", method: "POST", token: "", body: payload)
        guard response.status == 200 else { throw NSError(domain: "AgentMux", code: response.status, userInfo: [NSLocalizedDescriptionKey: String(decoding: response.data, as: UTF8.self)]) }
        let result = try JSONDecoder().decode([String: String].self, from: response.data)
        guard let token = result["token"], let deviceID = result["device_id"] else { throw URLError(.cannotParseResponse) }
        let mac = PairedMac(host: code.host, port: code.port, username: code.username, hostKey: code.hostKey, credential: token, deviceID: deviceID)
        try Keychain.save(String(decoding: JSONEncoder().encode(mac), as: UTF8.self), account: "paired-mac")
        await ssh.disconnect(); paired = mac
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
                SessionList().tabItem { Label("会话", systemImage: "terminal") }
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
struct SessionList: View {
    @EnvironmentObject var client: Client
    @State private var sessions: [AgentSession] = []
    @State private var creating = false
    var body: some View {
        NavigationStack {
            List {
                Section { PairingStatus() }
                if sessions.isEmpty, client.paired != nil {
                    ContentUnavailableView("暂无会话", systemImage: "terminal", description: Text("下拉刷新，或创建 Agent"))
                }
                ForEach(sessions) { session in
                    NavigationLink {
                        if session.mode == "structured" { ChatView(session: session) }
                        else { TerminalView(session: session) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(session.command, systemImage: "terminal")
                            Text(session.mode == "structured" ? "结构化聊天" : "tmux 终端兼容").font(.caption)
                            Text(session.directory).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("AgentMux")
            .toolbar { Button { creating = true } label: { Image(systemName: "plus") }; Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") } }
            .refreshable { await refresh() }
            .task(id: client.paired?.deviceID) { if client.paired != nil { await refresh() } }
            .sheet(isPresented: $creating, onDismiss: { Task { await refresh() } }) { CreateSession() }
        }
    }
    func refresh() async {
        await client.perform {
            let managed: [AgentSession] = try await client.get("/v1/managed")
            let terminal: [AgentSession] = try await client.get("/v1/sessions")
            sessions = managed + terminal
        }
    }
}
struct CreateSession: View {
    @EnvironmentObject var client: Client
    @Environment(\.dismiss) var dismiss
    @State private var agent = "codex"
    @State private var structured = true
    @State private var directory = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Picker("Agent", selection: $agent) { Text("Codex").tag("codex"); Text("Claude Code").tag("claude"); Text("Pi").tag("pi") }
                Toggle("结构化聊天", isOn: $structured)
                TextField("Mac 上的绝对目录", text: $directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("目录必须已存在且处于授权范围。使用 Mac 已配置的 Agent 登录状态。").font(.caption)
                Button("创建") {
                    busy = true
                    Task {
                        await client.perform { try await client.send(structured ? "/v1/managed" : "/v1/sessions", value: ["agent": agent, "directory": directory]); dismiss() }
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
struct TerminalView: View {
    @EnvironmentObject var client: Client
    @Environment(\.scenePhase) var scenePhase
    let session: AgentSession
    @State private var output = ""
    @State private var message = ""
    @State private var busy = false
    @State private var confirmInterrupt = false
    var body: some View {
        VStack {
            Text("终端快照 · 非结构化聊天").font(.caption).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(output.isEmpty ? "等待输出…" : output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            HStack {
                TextField("消息或 /命令", text: $message, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
                Button("发送") {
                    let text = message; busy = true
                    Task {
                        await client.perform { try await client.send("/v1/sessions/\(session.id)/input", value: ["text": text]); message = ""; try await refresh() }
                        busy = false
                    }
                }.disabled(message.isEmpty || busy)
            }.padding()
        }
        .navigationTitle(session.command)
        .toolbar { Button("中断", role: .destructive) { confirmInterrupt = true } }
        .confirmationDialog("发送 Ctrl-C？", isPresented: $confirmInterrupt) {
            Button("中断当前任务", role: .destructive) { Task { await client.perform { _ = try await client.request("/v1/sessions/\(session.id)/interrupt", method: "POST") } } }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await refresh(); try await Task.sleep(for: .seconds(2)) }
                catch { if !Task.isCancelled { client.error = error.localizedDescription }; break }
            }
        }
    }
    func refresh() async throws { output = String(decoding: try await client.request("/v1/sessions/\(session.id)/output"), as: UTF8.self) }
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
