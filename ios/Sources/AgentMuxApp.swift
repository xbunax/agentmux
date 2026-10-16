import SwiftUI
import Security
import UniformTypeIdentifiers

struct AgentSession: Codable, Identifiable, Hashable {
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
    var key: String { "\(mode):\(id):\(agentPID ?? 0)" }
    var projectName: String { (directory as NSString).lastPathComponent }
    var sourceName: String { mode == "plugin" ? "插件" : mode == "structured" ? "App 会话" : "tmux" }
    var displayName: String { command == "claude" ? "Claude Code" : command == "codex" ? "Codex" : command == "pi" ? "Pi" : command }
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
    private static func loadConnections() -> ConnectionStore {
        if let stored = try? JSONDecoder().decode(ConnectionStore.self, from: Data(Keychain.load(account: "connections-v2").utf8)) { return stored }
        if let old = try? JSONDecoder().decode(PairedMac.self, from: Data(Keychain.load(account: "paired-mac").utf8)) {
            return ConnectionStore(selectedID: old.deviceID, profiles: [old])
        }
        return ConnectionStore(selectedID: nil, profiles: [])
    }
    @Published private(set) var connections = Client.loadConnections()
    var paired: PairedMac? {
        #if DEBUG
        if InterfacePreview.enabled { return InterfacePreview.mac }
        #endif
        return connections.selected
    }
    @Published var error: String?
    @Published var isConnected = false
    @Published var connectionPath = ""
    var chatDrafts: [String: ChatDraftState] = [:]
    var attachmentURLs: [String: URL] = [:]
    let ssh = SSHTransport()
    let iroh = IrohTransport()
    private func persist(_ next: ConnectionStore) throws {
        try Keychain.save(String(decoding: JSONEncoder().encode(next), as: UTF8.self), account: "connections-v2")
        connections = next
    }
    private func save(_ mac: PairedMac) throws {
        var next = connections
        next.profiles.removeAll { $0.deviceID == mac.deviceID }
        next.profiles.append(mac); next.selectedID = mac.deviceID
        try persist(next)
        isConnected = true; error = nil
    }
    private func prepareIroh() async throws {
        let saved = Keychain.load(account: "iroh-identity")
        let key: Data
        if saved.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw URLError(.cannotCreateFile) }
            key = Data(bytes)
            try Keychain.save(key.base64EncodedString(), account: "iroh-identity")
        } else {
            guard let value = Data(base64Encoded: saved), value.count == 32 else { throw IrohError.message("设备身份损坏，请恢复钥匙串后重试") }
            key = value
        }
        try await iroh.setIdentity(key)
    }
    private func transport(for mac: PairedMac) async throws -> any AgentTransport {
        if mac.iroh != nil { try await prepareIroh(); return iroh }
        return ssh
    }
    func connectSSH(host: String, port: Int, username: String, hostKey: String, login: SSHLogin) async throws {
        let mac = try await ssh.connectSSH(host: host, port: port, username: username, hostKey: hostKey, login: login, deviceName: "AgentMux iPhone")
        do { try Task.checkCancellation(); try save(mac) }
        catch {
            _ = try? await ssh.request(profile: mac, path: "/v1/devices/\(mac.deviceID)", method: "DELETE", token: mac.credential, body: nil)
            await ssh.disconnect(); throw error
        }
    }
    func connectIroh(_ code: IrohPairCode) async throws {
        try await prepareIroh()
        let mac = try await iroh.pair(code, name: UIDevice.current.name)
        do {
            try Task.checkCancellation()
            let response = try await iroh.request(profile: mac, path: "/v1/settings", method: "GET", token: mac.credential, body: nil)
            guard response.status == 200 else { throw IrohError.message("配对成功，但服务验证失败（\(response.status)）") }
            try save(mac)
            await refreshConnectionPath()
        } catch {
            _ = try? await iroh.request(profile: mac, path: "/v1/devices/\(mac.deviceID)", method: "DELETE", token: mac.credential, body: nil)
            await iroh.disconnect(); throw error
        }
    }
    func selectConnection(_ mac: PairedMac) async {
        await perform {
            var next = connections; next.selectedID = mac.deviceID
            try persist(next); isConnected = false; connectionPath = ""
            await ssh.disconnect(); await iroh.disconnect()
        }
    }
    func refreshConnectionPath() async {
        connectionPath = paired?.iroh != nil ? await iroh.pathDescription() : "SSH · 加密连接"
    }
    func terminalStream(generation: String) async throws -> TerminalStream {
        guard let paired else { throw IrohError.message("请先连接 Mac") }
        return try await transport(for: paired).terminalStream(profile: paired, generation: generation)
    }
    func forget() async {
        await perform {
            if let paired {
                do { _ = try await request("/v1/devices/\(paired.deviceID)", method: "DELETE") }
                catch let error as NSError where error.domain == "AgentMux" && error.code == 401 { /* Already revoked. */ }
                var next = connections
                next.profiles.removeAll { $0.deviceID == paired.deviceID }
                next.selectedID = next.profiles.first?.deviceID
                try persist(next)
            }
            await ssh.disconnect(); await iroh.disconnect(); isConnected = false; connectionPath = ""
        }
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        #if DEBUG
        if InterfacePreview.enabled { isConnected = true; return try InterfacePreview.response(path, method: method) }
        #endif
        guard let paired else { throw NSError(domain: "AgentMux", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先连接 Mac"]) }
        var url = URLComponents(); url.path = path; url.queryItems = query.isEmpty ? nil : query
        guard let uri = url.string else { throw URLError(.badURL) }
        let response: SSHResponse
        do {
            response = try await transport(for: paired).request(profile: paired, path: uri, method: method, token: paired.credential, body: body)
        } catch {
            if !(error is CancellationError) { isConnected = false }
            throw error
        }
        guard (200..<300).contains(response.status) else {
            if response.status == 401 { isConnected = false }
            throw NSError(domain: "AgentMux", code: response.status, userInfo: [NSLocalizedDescriptionKey: String(decoding: response.data, as: UTF8.self)])
        }
        if !isConnected { isConnected = true }
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
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case sessions, files, settings
    var id: String { rawValue }
    var title: String { self == .sessions ? "会话" : self == .files ? "文件" : "设置" }
    var symbol: String { self == .sessions ? "bubble.left.and.bubble.right.fill" : self == .files ? "folder.fill" : "gearshape.fill" }
}

@main struct AgentMuxApp: App {
    @AppStorage("colorPalette") private var palette = ColorPalette.agentmux.rawValue
    private var theme: AppTheme { AppTheme(palette: ColorPalette(rawValue: palette) ?? .agentmux) }
    @StateObject var client = Client()
    @AppStorage("appearance") private var appearance = "dark"
    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(client)
                .environment(\.appTheme, theme)
                .tint(theme.accent)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark)
                .alert("操作未完成", isPresented: Binding(get: { client.error != nil }, set: { if !$0 { client.error = nil } })) {
                    Button("知道了") { client.error = nil }
                } message: { Text(client.error ?? "") }
        }
    }
    @ViewBuilder private var root: some View {
        #if DEBUG
        if InterfacePreview.enabled { InterfacePreviewRoot() } else { WorkspaceRoot() }
        #else
        WorkspaceRoot()
        #endif
    }
}

struct WorkspaceRoot: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var client: Client
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var tab: WorkspaceTab = .sessions
    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    List(WorkspaceTab.allCases, selection: Binding<WorkspaceTab?>(get: { tab }, set: { if let value = $0 { tab = value } })) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                            .padding(.vertical, 6)
                    }.appList().navigationTitle("AgentMux")
                        .safeAreaInset(edge: .bottom) {
                            Label(client.paired?.host ?? "尚未连接 Mac", systemImage: "desktopcomputer")
                                .font(.caption).foregroundStyle(theme.secondary).padding()
                        }
                } detail: { destination(tab) }
            } else {
                TabView(selection: $tab) {
                    ForEach(WorkspaceTab.allCases) { item in
                        destination(item).tabItem { Label(item.title, systemImage: item.symbol) }.tag(item)
                    }
                }
            }
        }.tint(theme.accent)
    }
    @ViewBuilder private func destination(_ tab: WorkspaceTab) -> some View {
        switch tab {
        case .sessions: SessionList()
        case .files: FileBrowser()
        case .settings: SettingsView()
        }
    }
}
