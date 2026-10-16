import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var client: Client
    @State private var config: ServiceConfig?
    @State private var directory = ""
    @State private var roots = ""
    @State private var saved = false
    @AppStorage("appearance") private var appearance = "dark"
    @AppStorage("terminalFollowSize") private var followSize = false
    @AppStorage("terminalAutoHide") private var autoHide = true
    @AppStorage("terminalHaptics") private var haptics = true
    var body: some View {
        NavigationStack {
            Form {
                Section { PairingStatus() }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                Section("外观") {
                    Picker("明暗模式", selection: $appearance) {
                        Text("深色").tag("dark"); Text("浅色").tag("light"); Text("跟随系统").tag("system")
                    }.pickerStyle(.segmented)
                    NavigationLink { PalettePicker() } label: { LabeledContent("配色方案", value: theme.palette.title) }
                }.listRowBackground(theme.surface)
                Section {
                    Toggle("终端尺寸跟随手机", isOn: $followSize)
                    Toggle("浏览时自动隐藏控制栏", isOn: $autoHide)
                    Toggle("控制栏触觉反馈", isOn: $haptics)
                    NavigationLink("自定义 Micro 按钮") { MicroCustomization() }
                } header: { Text("终端") } footer: {
                    Text("尺寸跟随会调整 Mac 上同一 tmux 窗口的排版，关闭或断开后恢复。多窗格保留分屏。浏览时可自动隐藏控制栏，底部按钮可随时恢复。触觉反馈仅表示手机接受操作。")
                }.listRowBackground(theme.surface)
                Section("Mac 服务") {
                    Button("读取服务配置") { Task { await load() } }
                    if let config {
                        Text("配置版本 \(config.revision)")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("默认目录").font(.subheadline)
                            TextField("Mac 上的目录", text: $directory, axis: .vertical)
                                .font(.callout.monospaced()).foregroundStyle(theme.secondary)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }.padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("授权目录").font(.subheadline)
                            TextField("每行一个目录", text: $roots, axis: .vertical)
                                .font(.callout.monospaced()).foregroundStyle(theme.secondary)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }.padding(.vertical, 4)
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
                }.listRowBackground(theme.surface)
                Section("关于") {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("AgentMux").font(.body.weight(.semibold))
                            Text("随时继续你的 Agent 工作").font(.caption).foregroundStyle(theme.secondary)
                        }
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").font(.caption).foregroundStyle(theme.secondary)
                    }.padding(.vertical, 5)
                }.listRowBackground(theme.surface)
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
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var client: Client
    @State private var path = ""
    @State private var currentPath = ""
    @State private var roots: [String] = []
    @State private var entries: [FileEntry] = []
    @State private var importing = false
    @State private var downloaded: URL?
    @State private var busy = false
    @State private var loaded = false
    @State private var search = ""
    @State private var editingPath = false
    @State private var directoryDraft = ""
    private var filteredEntries: [FileEntry] {
        entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below").font(.title2).foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.paired?.host ?? "尚未连接 Mac").font(.subheadline.weight(.semibold))
                            Text("远程文件").font(.caption).foregroundStyle(theme.secondary)
                        }
                        Spacer()
                        if busy { ProgressView() }
                        if !roots.isEmpty {
                            Menu {
                                ForEach(roots, id: \.self) { root in Button(root) { path = root; Task { await load() } } }
                            } label: { Image(systemName: "folder.badge.gearshape").frame(width: 44, height: 44) }.accessibilityLabel("选择授权目录")
                        }
                    }
                    Button { directoryDraft = currentPath; editingPath = true } label: {
                        LabeledContent("前往文件夹") {
                            Text(currentPath.isEmpty ? "选择目录" : (currentPath as NSString).lastPathComponent)
                                .lineLimit(1).foregroundStyle(theme.secondary)
                        }
                    }.disabled(busy || client.paired == nil)
                }.listRowBackground(theme.surface)
                Section {
                    if loaded && entries.isEmpty {
                        EmptyState(symbol: "folder", title: "这个文件夹是空的", detail: "轻点右上角，上传文件到当前目录。")
                    }
                    if loaded && !entries.isEmpty && filteredEntries.isEmpty {
                        Text("没有匹配的文件").foregroundStyle(theme.secondary)
                    }
                    ForEach(filteredEntries) { entry in
                        Button {
                            if entry.directory { path = (currentPath as NSString).appendingPathComponent(entry.name); Task { await load() } }
                            else { Task { await download(entry) } }
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: entry.directory ? "folder.fill" : "doc.fill")
                                    .font(.title3).foregroundStyle(entry.directory ? theme.accent : theme.secondary)
                                    .frame(width: 30, height: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name).font(.body).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                                    if !entry.directory {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                            .font(.caption).foregroundStyle(theme.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: entry.directory ? "chevron.right" : "arrow.down.circle").font(.subheadline).foregroundStyle(theme.secondary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.disabled(busy)
                    }
                } header: {
                    HStack { Text(currentPath.isEmpty ? "目录内容" : (currentPath as NSString).lastPathComponent); Spacer(); Text("\(filteredEntries.count) 项") }.textCase(nil)
                } footer: { Text("单文件上限 8 MiB。上传保留已有文件，不覆盖同名文件。") }
                    .listRowBackground(theme.surface)
                if let downloaded { Section { ShareLink(item: downloaded) { Label("保存或分享已下载文件", systemImage: "square.and.arrow.up") } }.listRowBackground(theme.surface) }
            }.appList().navigationTitle("文件").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索当前文件夹")
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
                .sheet(isPresented: $editingPath) {
                    NavigationStack {
                        Form {
                            Section("Mac 上的目录") {
                                TextField("绝对路径", text: $directoryDraft, axis: .vertical)
                                    .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                            }.listRowBackground(theme.surface)
                        }.appList().navigationTitle("前往文件夹").navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("取消") { editingPath = false }
                                }
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("打开") { path = directoryDraft; editingPath = false; Task { await load() } }.disabled(directoryDraft.isEmpty || busy)
                                }
                            }
                    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                }
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
            if currentPath != requestedPath { search = "" }
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

struct PalettePicker: View {
    @AppStorage("colorPalette") private var selection = ColorPalette.agentmux.rawValue
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(ColorPalette.allCases) { palette in
                    Button { selection = palette.rawValue } label: {
                        PalettePreview(palette: palette, selected: selection == palette.rawValue)
                    }.buttonStyle(.plain).accessibilityLabel(palette.title + "，" + palette.detail)
                        .accessibilityAddTraits(selection == palette.rawValue ? .isSelected : [])
                }
            }.padding(16)
        }.background(AppBackdrop()).navigationTitle("配色方案").navigationBarTitleDisplayMode(.inline)
    }
}
private struct PalettePreview: View {
    let palette: ColorPalette
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    private var preview: AppTheme { AppTheme(palette: palette) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(palette.title).font(.headline)
                    Text(palette.detail).font(.caption).foregroundStyle(preview.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(preview.accent).font(.title2)
            }
            HStack(spacing: 8) {
                ForEach(Array(palette.ansi(dark: scheme == .dark).prefix(8).enumerated()), id: \.offset) { _, value in
                    Circle().fill(Color.adaptive(light: value, dark: value)).frame(width: 22, height: 22)
                }
            }
            HStack { Image(systemName: "bubble.left.and.bubble.right"); Text("继续你的 Agent 会话"); Spacer(); Image(systemName: "arrow.up") }
                .font(.caption).padding(10).appGlass(radius: 12)
            Text("❯ agentmux\n✓ Ready · 中文输入").font(.system(.caption, design: .monospaced)).foregroundStyle(preview.accent)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(preview.background, in: RoundedRectangle(cornerRadius: 12))
        }.padding(16).foregroundStyle(preview.text).appGlass(radius: 22).environment(\.appTheme, preview)
    }
}
