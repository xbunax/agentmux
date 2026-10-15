import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var client: Client
    @State private var config: ServiceConfig?
    @State private var directory = ""
    @State private var roots = ""
    @State private var saved = false
    @AppStorage("appearance") private var appearance = "dark"
    var body: some View {
        NavigationStack {
            Form {
                Section { PairingStatus() }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        Text("深色").tag("dark"); Text("浅色").tag("light"); Text("跟随系统").tag("system")
                    }.pickerStyle(.segmented)
                }.listRowBackground(AppTheme.surface)
                Section("Mac 服务") {
                    Button("读取服务配置") { Task { await load() } }
                    if let config {
                        Text("配置版本 \(config.revision)")
                        TextField("默认目录", text: $directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("授权目录，每行一个", text: $roots, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                        DisclosureGroup("Agent 可执行路径") {
                            LabeledContent("Codex", value: config.agents.codex)
                            LabeledContent("Claude Code", value: config.agents.claude)
                            LabeledContent("Pi", value: config.agents.pi)
                        }.font(.caption)
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
                }.listRowBackground(AppTheme.surface)
                Section("关于") {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("AgentMux").font(.body.weight(.semibold))
                            Text("随时继续你的 Agent 工作").font(.caption).foregroundStyle(AppTheme.secondary)
                        }
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").font(.caption).foregroundStyle(AppTheme.secondary)
                    }.padding(.vertical, 5)
                }.listRowBackground(AppTheme.surface)
            }.appList().navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .task(id: client.paired?.deviceID) { if client.paired != nil { await load() } }
                .alert("配置已应用", isPresented: $saved) { Button("确定", role: .cancel) {} }
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
    @State private var currentPath = ""
    @State private var roots: [String] = []
    @State private var entries: [FileEntry] = []
    @State private var importing = false
    @State private var downloaded: URL?
    @State private var busy = false
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below").font(.title2).foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.paired?.host ?? "尚未连接 Mac").font(.subheadline.weight(.semibold))
                            Text("远程文件").font(.caption).foregroundStyle(AppTheme.secondary)
                        }
                        Spacer()
                        if busy { ProgressView() }
                        if !roots.isEmpty {
                            Menu {
                                ForEach(roots, id: \.self) { root in Button(root) { path = root; Task { await load() } } }
                            } label: { Image(systemName: "folder.badge.gearshape").frame(width: 44, height: 44) }.accessibilityLabel("选择授权目录")
                        }
                    }.padding(.vertical, 7)
                    HStack(spacing: 8) {
                        TextField("Mac 目录", text: $path).font(.subheadline.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { Task { await load() } }
                        Button { Task { await load() } } label: { Image(systemName: "arrow.right.circle.fill").font(.title3) }.frame(width: 44, height: 44).disabled(busy || path.isEmpty).accessibilityLabel("打开目录")
                    }
                }.listRowBackground(AppTheme.surface)
                Section {
                    if loaded && entries.isEmpty {
                        EmptyState(symbol: "folder", title: "这个文件夹是空的", detail: "轻点右上角，上传文件到当前目录。")
                    }
                    ForEach(entries) { entry in
                        Button {
                            if entry.directory { path = (currentPath as NSString).appendingPathComponent(entry.name); Task { await load() } }
                            else { Task { await download(entry) } }
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: entry.directory ? "folder.fill" : "doc.fill")
                                    .font(.title3).foregroundStyle(entry.directory ? AppTheme.accent : AppTheme.secondary)
                                    .frame(width: 38, height: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name).font(.body).foregroundStyle(AppTheme.text).lineLimit(2)
                                    Text(entry.directory ? "文件夹" : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                        .font(.caption).foregroundStyle(AppTheme.secondary)
                                }
                                Spacer()
                                Image(systemName: entry.directory ? "chevron.right" : "arrow.down.circle").font(.subheadline).foregroundStyle(AppTheme.secondary)
                            }.padding(.vertical, 5)
                        }.disabled(busy)
                    }
                } header: {
                    HStack { Text(currentPath.isEmpty ? "目录内容" : (currentPath as NSString).lastPathComponent); Spacer(); Text("\(entries.count) 项") }.textCase(nil)
                } footer: { Text("单文件上限 8 MiB。上传保留已有文件，不覆盖同名文件。") }
                    .listRowBackground(AppTheme.surface)
                if let downloaded { Section { ShareLink(item: downloaded) { Label("保存或分享已下载文件", systemImage: "square.and.arrow.up") } }.listRowBackground(AppTheme.surface) }
            }.appList().navigationTitle("文件").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { path = (currentPath as NSString).deletingLastPathComponent; Task { await load() } } label: { Image(systemName: "arrow.up") }
                            .disabled(busy || currentPath.isEmpty || roots.contains(currentPath)).accessibilityLabel("上一级目录")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { importing = true } label: { Image(systemName: "square.and.arrow.up") }
                            .disabled(currentPath.isEmpty || busy || path != currentPath).accessibilityLabel("上传文件到当前目录")
                    }
                }
                .refreshable { await load() }
                .task(id: client.paired?.deviceID) {
                    guard client.paired != nil else { entries = []; currentPath = ""; loaded = false; return }
                    await client.perform {
                        let config: ServiceConfig = try await client.get("/v1/settings")
                        roots = config.roots
                        if path.isEmpty { path = config.defaultDirectory }
                        await load()
                    }
                }
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
                        let destination = (currentPath as NSString).appendingPathComponent(url.lastPathComponent)
                        _ = try await client.request(
                            "/v1/file", method: "PUT", body: data,
                            query: [URLQueryItem(name: "path", value: destination)]
                        )
                        busy = false
                        await load()
                    }
                }
            }
        }
    }
    func load() async {
        guard !path.isEmpty, !busy else { return }
        busy = true; defer { busy = false }
        let requestedPath = path
        await client.perform {
            let next: [FileEntry] = try await client.get("/v1/files", query: [URLQueryItem(name: "path", value: requestedPath)])
            currentPath = requestedPath
            entries = next.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loaded = true
        }
    }
    func download(_ entry: FileEntry) async {
        busy = true; defer { busy = false }
        await client.perform {
            let data = try await client.request("/v1/file", query: [URLQueryItem(name: "path", value: (currentPath as NSString).appendingPathComponent(entry.name))])
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(entry.name)
            try data.write(to: file, options: .atomic); downloaded = file
        }
    }
}
