import SwiftUI
import Crypto
import UniformTypeIdentifiers
import PhotosUI

enum WorkbenchMode: String, CaseIterable { case text = "文本", micro = "Micro", glide = "滑控"
    var icon: String { self == .text ? "keyboard" : self == .micro ? "dpad" : "hand.draw" }
}
struct SessionDestination: View {
    let session: AgentSession
    let availableSessions: [AgentSession]
    var body: some View {
        if ["tmux", "generic"].contains(session.mode) || session.nativePaneID != nil {
            TerminalWorkbench(session: session, availableSessions: availableSessions)
        } else { ChatView(session: session, availableSessions: availableSessions) }
    }
}
struct TerminalWorkbench: View {
    let session: AgentSession
    let availableSessions: [AgentSession]
    @EnvironmentObject private var client: Client
    @Environment(\.scenePhase) private var phase
    @StateObject private var model: TerminalSessionModel
    @State private var mode: WorkbenchMode = .text
    @State private var direct = false
    @State private var directFocus = false
    @FocusState private var draftFocus: Bool
    @State private var draft = ""
    @State private var attempted = ""
    @State private var height: CGFloat = 240
    @State private var dragStart: CGFloat?
    @State private var collapsed = false
    @State private var keyboard = false
    @State private var confirmTarget = true
    @State private var confirmPaste = false
    @State private var pendingPaste: String?
    @State private var enhancements = false
    @State private var importing = false
    @State private var photoPicker = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var uploading = false
    @State private var shortcuts: [String] = []
    @State private var arrows = false
    @State private var lastDrag = CGSize.zero
    @State private var lastArrow = Date.distantPast
    @State private var glideMeaning: Bool?
    init(session: AgentSession, availableSessions: [AgentSession]) {
        self.session = session; self.availableSessions = availableSessions
        _model = StateObject(wrappedValue: TerminalSessionModel(session: session))
    }
    private var draftKey: String {
        let host = client.paired.map { "\($0.host):\($0.port):\($0.username):\($0.hostKey)" } ?? "offline"
        return "terminal-draft." + SHA256.hash(data: Data((host + ":" + session.key).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                targetBar
                TerminalSurface(model: model)
                    .overlay(alignment: .topTrailing) {
                        if let grid = model.attachment { Text("\(grid.cols) × \(grid.rows)").font(.caption2.monospacedDigit()).padding(7).workbenchGlass().padding(8).allowsHitTesting(false) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                workbench(height: collapsed ? 48 : min(height, keyboard ? 200 : max(160, geometry.size.height * 0.52)))
            }.background(AppTheme.background)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) { Text(session.projectName).font(.headline).lineLimit(1) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重新确认控制目标") { model.stop(); directFocus = false; confirmTarget = true }
                    if session.mode != "generic" { Button("原生增强、附件与记录") { model.stop(); directFocus = false; enhancements = true } }
                    Button(collapsed ? "展开工作台" : "收起工作台") { collapse() }
                    if !attempted.isEmpty && attempted != draft {
                        Button("将上次填入副本追加到草稿") { draft += (draft.isEmpty ? "" : "\n") + attempted; switchMode(.text); direct = false }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
            }
        }
        .confirmationDialog("连接原终端", isPresented: $confirmTarget, titleVisibility: .visible) {
            Button("连接 \(model.paneID ?? session.name)") { model.connect(client) }
            Button("暂不连接", role: .cancel) {}
        } message: { Text("\(session.displayName) · \(session.name)\n手机输入会进入这个原有进程。Mac 键盘仍可同时操作；请先看清现场。") }
        .confirmationDialog("填入当前终端焦点？", isPresented: $confirmPaste, titleVisibility: .visible) {
            Button("确认填入，不追加 Enter") {
                guard let text = pendingPaste else { return }
                attempted = text; saveDraft(); model.paste(text, confirmed: true); pendingPaste = nil
            }
            Button("取消", role: .cancel) { pendingPaste = nil }
        } message: { Text("不会清空 Mac 草稿。多行文本由远端程序解释，即使不追加 Enter，也可能触发提交。填入后保留本地副本，它不是远端输入区的实时镜像。") }
        .sheet(isPresented: $enhancements) {
            NavigationStack { ChatView(session: session, availableSessions: [session], nativeOnly: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回终端") { enhancements = false; confirmTarget = true } } } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            Task {
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else { throw attachmentError("附件不能超过 8 MiB") }
                    try await attach(data: Data(contentsOf: url), name: url.lastPathComponent)
                } catch { client.error = error.localizedDescription }
            }
        }
        .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 1, matching: .images)
        .onChange(of: photos) { _, selection in
            Task {
                do {
                    guard let item = selection.first, let data = try await item.loadTransferable(type: Data.self) else { return }
                    let file = try PendingAttachment.photo(data: data)
                    try await attach(data: Data(contentsOf: file.url), name: file.name)
                } catch { client.error = error.localizedDescription }
                photos = []
            }
        }
        .onAppear {
            draft = UserDefaults.standard.string(forKey: draftKey) ?? ""
            attempted = UserDefaults.standard.string(forKey: draftKey + ".attempted") ?? ""
            shortcuts = Array((UserDefaults.standard.stringArray(forKey: draftKey + ".shortcuts") ?? []).prefix(6))
            #if DEBUG
            if InterfacePreview.enabled { loadPreview() }
            #endif
        }
        .onDisappear { saveDraft(); model.stop() }
        .onChange(of: draft) { _, _ in saveDraft() }
        .onChange(of: phase) { _, value in if value != .active { model.stop(); directFocus = false } }
        .onChange(of: model.active) { _, value in if !value { directFocus = false } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false; directFocus = false }
    }
    private var targetBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.active ? AppTheme.accent : AppTheme.warning).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.displayName) · \(model.paneID ?? "")").font(.caption.weight(.semibold))
                Text(model.status).font(.caption2).foregroundStyle(model.uncertain ? AppTheme.warning : AppTheme.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !model.active { Button("连接") { confirmTarget = true }.font(.caption).frame(minWidth: 44, minHeight: 44).disabled(model.connecting) }
            if keyboard { Button { draftFocus = false; directFocus = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44) }.accessibilityLabel("收起键盘") }
        }.padding(.horizontal, 16).frame(minHeight: 44)
    }
    private func workbench(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(AppTheme.secondary.opacity(0.5)).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity).frame(height: 44).contentShape(Rectangle())
                .onTapGesture { collapse() }
                .gesture(DragGesture(minimumDistance: 5).onChanged { value in
                    if dragStart == nil { dragStart = self.height }
                    collapsed = false; self.height = min(420, max(160, (dragStart ?? self.height) - value.translation.height))
                }.onEnded { _ in dragStart = nil })
                .accessibilityLabel("调整工作台高度").accessibilityAdjustableAction { direction in
                    collapsed = false; self.height = min(420, max(160, self.height + (direction == .increment ? 40 : -40)))
                }
            if !collapsed {
                HStack(spacing: 8) {
                    Group {
                        switch mode { case .text: textPanel; case .micro: microPanel; case .glide: glidePanel }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 2) {
                        ForEach(WorkbenchMode.allCases, id: \.self) { item in
                            Button { switchMode(item) } label: {
                                VStack(spacing: 3) { Image(systemName: item.icon).font(.system(size: 17)); Text(item.rawValue).font(.system(size: 10, weight: .medium)) }
                                    .frame(width: 48, height: 44)
                                    .foregroundStyle(mode == item ? AppTheme.accent : AppTheme.secondary)
                                    .background(mode == item ? AppTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 13))
                            }.buttonStyle(.plain).accessibilityLabel("\(item.rawValue)模式").accessibilityAddTraits(mode == item ? .isSelected : [])
                        }
                    }.padding(3).workbenchGlass()
                }.padding(.horizontal, 12).padding(.bottom, 10)
            }
        }.frame(height: height).frame(maxWidth: .infinity).workbenchGlass(radius: 26)
    }
    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Button { direct = false; directFocus = false; draftFocus = true } label: { Text("本地草稿").font(.caption.weight(.semibold)).frame(minHeight: 44) }
                    .foregroundStyle(!direct ? AppTheme.text : AppTheme.secondary)
                Text("/").foregroundStyle(AppTheme.secondary)
                Button { draftFocus = false; direct = true; directFocus = true } label: { Text("终端直输").font(.caption.weight(.semibold)).frame(minHeight: 44) }
                    .foregroundStyle(direct ? AppTheme.accent : AppTheme.secondary)
                Spacer(minLength: 0)
            }
            if direct {
                Text("正在输入到终端").font(.caption2).foregroundStyle(AppTheme.warning)
                TerminalKeyboard(enabled: model.canWrite, focused: $directFocus, commit: { text in
                    if text.contains("\n") && text != "\n" { pendingPaste = text; confirmPaste = true }
                    else { model.committed(text) }
                }, key: model.key)
                .frame(minHeight: 32).background(AppTheme.elevated.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                if !keyboard { Text("点按此处唤起键盘；回车就是 Enter").font(.caption2).foregroundStyle(AppTheme.secondary).onTapGesture { directFocus = true } }
            } else {
                TextEditor(text: $draft).focused($draftFocus).scrollContentBackground(.hidden)
                    .font(.body).frame(minHeight: 30).accessibilityLabel("此会话的本地草稿")
                HStack {
                    Menu {
                        Button("添加文件") { importing = true }
                        Button("添加照片") { photoPicker = true }
                    } label: { Image(systemName: uploading ? "arrow.up.doc" : "paperclip").frame(width: 44, height: 44) }
                    .disabled(uploading || client.paired == nil).accessibilityLabel("上传附件并加入草稿")
                    if !keyboard { Text(attempted == draft && !draft.isEmpty ? "保留副本 · 非远端镜像" : "本地编辑，不逐字同步").font(.caption2).foregroundStyle(AppTheme.secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    Button { submit() } label: {
                        Label(model.canSendNative ? "发送" : "填入终端", systemImage: model.canSendNative ? "arrow.up" : "text.insert")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 44)
                            .background(AppTheme.accent.opacity(0.14), in: Capsule())
                    }.disabled(!model.canWrite || model.writing || draft.isEmpty || (!draft.isEmpty && attempted == draft))
                    if attempted == draft && !draft.isEmpty { Button("再填入") { pendingPaste = draft; confirmPaste = true }.font(.caption2).frame(minHeight: 44).disabled(!model.canWrite || model.writing) }
                }
            }
        }
    }
    private var microPanel: some View {
        ScrollView {
            VStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 4) {
                    Menu {
                        ForEach(availableSessions.filter { $0.key != session.key }) { target in
                            Button {
                                if shortcuts.contains(target.key) { shortcuts.removeAll { $0 == target.key } }
                                else if shortcuts.count < 6 { shortcuts.append(target.key) }
                                UserDefaults.standard.set(shortcuts, forKey: draftKey + ".shortcuts")
                            } label: { Label(target.projectName + " · " + target.displayName, systemImage: shortcuts.contains(target.key) ? "checkmark.circle.fill" : "circle") }
                            .disabled(!shortcuts.contains(target.key) && shortcuts.count >= 6)
                        }
                    } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.accessibilityLabel("配置最多六个会话快捷键")
                    ForEach(Array(availableSessions.filter { $0.key != session.key && shortcuts.contains($0.key) }.prefix(6))) { target in
                        NavigationLink(value: target) { Text(target.projectName.prefix(5)).font(.caption2).lineLimit(1).frame(minWidth: 44, minHeight: 44).background(AppTheme.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 9)) }
                    }
                } }
                HStack(spacing: 4) {
                    keyButton("Esc", "Escape")
                    VStack(spacing: 0) {
                        keyButton("↑", "Up")
                        HStack(spacing: 2) { keyButton("←", "Left"); keyButton("↓", "Down"); keyButton("→", "Right") }
                    }
                    keyButton("Enter", "Enter")
                }
                HStack(spacing: 2) {
                    keyButton("Tab", "Tab"); keyButton("⇧Tab", "BTab"); keyButton("Space", "Space")
                    Menu {
                        ForEach(["BSpace", "DC", "Home", "End", "PPage", "NPage", "C-c", "C-d"], id: \.self) { key in
                            Button(key == "C-c" ? "Ctrl-C（中断信号）" : key == "C-d" ? "Ctrl-D" : key) { model.key(key) }
                        }
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }.disabled(!model.canWrite)
                }
            }
        }.scrollIndicators(.hidden)
    }
    private func keyButton(_ title: String, _ key: String) -> some View {
        Button { model.key(key) } label: { Text(title).font(.system(size: 13, weight: .medium, design: .monospaced)).frame(minWidth: 44, minHeight: 44).background(AppTheme.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 10)) }
            .buttonStyle(.plain).disabled(!model.canWrite).accessibilityLabel(key)
    }
    private var glidePanel: some View {
        VStack(spacing: 6) {
            Picker("手势含义", selection: $arrows) { Text("浏览").tag(false); Text("方向键").tag(true) }.pickerStyle(.segmented)
                .disabled(glideMeaning != nil)
            ZStack {
                RoundedRectangle(cornerRadius: 17).fill(AppTheme.elevated.opacity(0.45))
                VStack(spacing: 8) { Image(systemName: arrows ? "arrow.up.and.down.and.arrow.left.and.right" : "viewfinder").font(.title2); Text(arrows ? "滑动发送方向键 · 不会确认" : "移动手机视口 · 不向 Mac 输入").font(.caption2) }.foregroundStyle(AppTheme.secondary).allowsHitTesting(false)
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 8).onChanged { value in
                if glideMeaning == nil { glideMeaning = arrows; lastDrag = .zero }
                let dx = value.translation.width - lastDrag.width, dy = value.translation.height - lastDrag.height
                if glideMeaning == true {
                    guard Date().timeIntervalSince(lastArrow) >= 0.12, max(abs(dx), abs(dy)) >= 20 else { return }
                    model.key(abs(dx) > abs(dy) ? (dx > 0 ? "Right" : "Left") : (dy > 0 ? "Down" : "Up"))
                    lastArrow = Date(); lastDrag = value.translation
                } else { model.browse?(-dx, -dy); lastDrag = value.translation }
            }.onEnded { _ in model.cancelNavigation(); lastDrag = .zero; glideMeaning = nil })
            HStack { keyButton("Esc", "Escape"); Spacer(); keyButton("Enter", "Enter") }
        }
    }
    private func submit() {
        guard model.canWrite, !model.writing, attempted != draft else { return }
        if model.canSendNative { attempted = draft; saveDraft(); model.nativeSend(draft) }
        else { pendingPaste = draft; confirmPaste = true }
    }
    private func attach(data: Data, name: String) async throws {
        guard !uploading else { return }
        uploading = true; defer { uploading = false }
        let file = try PendingAttachment.store(data: data, name: name)
        let response = try await client.request("/v1/attachments/" + file.id, method: "PUT", body: data, query: [URLQueryItem(name: "name", value: file.name)])
        let receipt = try JSONDecoder().decode(RemoteAttachment.self, from: response)
        guard let path = receipt.path else { throw attachmentError("附件未返回 Mac 路径") }
        client.attachmentURLs[receipt.id] = file.url
        // Uploading does not write to the terminal or send an Agent turn.
        draft += (draft.isEmpty ? "" : "\n") + "附件：" + path
        saveDraft()
    }
    private func saveDraft() { UserDefaults.standard.set(draft, forKey: draftKey); UserDefaults.standard.set(attempted, forKey: draftKey + ".attempted") }
    private func collapse() { collapsed.toggle(); draftFocus = false; directFocus = false; model.cancelNavigation() }
    private func switchMode(_ next: WorkbenchMode) {
        model.cancelNavigation(); glideMeaning = nil; lastDrag = .zero
        draftFocus = false; directFocus = false; mode = next
    }
    #if DEBUG
    private func loadPreview() {
        confirmTarget = false
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--preview-micro") { mode = .micro }
        if args.contains("--preview-glide") { mode = .glide }
        draft = "请检查输入焦点切换，保留 Mac 上已有草稿。"
        model.preview()
        if args.contains("--preview-keyboard") { draftFocus = true }
    }
    #endif
}
private struct WorkbenchGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    var radius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency { content.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: radius)) }
        else if #available(iOS 26.0, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius)) }
    }
}
extension View { fileprivate func workbenchGlass(radius: CGFloat = 16) -> some View { modifier(WorkbenchGlass(radius: radius)) } }
