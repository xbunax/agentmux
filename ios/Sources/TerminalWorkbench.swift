import SwiftUI
import Crypto
import UniformTypeIdentifiers
import PhotosUI

enum WorkbenchMode: String, CaseIterable { case text = "文本", micro = "Micro", glide = "滑控"
    var icon: String { self == .text ? "keyboard" : self == .micro ? "dpad" : "hand.draw" }
}
struct SessionDestination: View {
    @Environment(\.appTheme) private var theme
    let session: AgentSession
    let availableSessions: [AgentSession]
    var body: some View {
        if ["tmux", "generic"].contains(session.mode) || session.nativePaneID != nil {
            TerminalWorkbench(session: session, availableSessions: availableSessions)
        } else { ChatView(session: session, availableSessions: availableSessions) }
    }
}
struct TerminalWorkbench: View {
    @Environment(\.appTheme) private var theme
    let session: AgentSession
    let availableSessions: [AgentSession]
    @EnvironmentObject private var client: Client
    @Environment(\.scenePhase) private var phase
    @StateObject private var model: TerminalSessionModel
    @AppStorage("workbenchMode") private var mode: WorkbenchMode = .micro
    @AppStorage("terminalAutoHide") private var autoHide = true
    @AppStorage("terminalHaptics") private var haptics = true
    @AppStorage(MicroLayout.storageKey) private var storedMicroLayout = MicroLayout.defaultValue
    @AppStorage("terminalFollowSize") private var followSize = false
    @AppStorage("dictationHintSeen") private var dictationHintSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var feedback = UISelectionFeedbackGenerator()
    @State private var shown = false
    @State private var resumeOnActive = false
    @State private var details = false
    @State private var customizingMicro = false
    @State private var dictationHint = false
    @State private var direct = false
    @State private var directFocus = false
    @FocusState private var draftFocus: Bool
    @State private var draft = ""
    @State private var attempted = ""
    @State private var collapsed = false
    @State private var keyboard = false
    @State private var enhancements = false
    @State private var importing = false
    @State private var photoPicker = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var uploading = false
    @State private var shortcuts: [String] = []
    @State private var arrows = false
    @State private var lastDrag = CGSize.zero
    @State private var lastArrow = Date.distantPast
    @State private var browseMoved = false
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
                TerminalSurface(model: model, onBrowse: hideForBrowsing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .appGlass(radius: 18).clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 6)
                if collapsed {
                    Button { collapse() } label: {
                        Label("显示控制栏", systemImage: "chevron.up").font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity).frame(height: 44)
                    }.accessibilityHint("恢复文本、Micro 和滑控面板")
                } else {
                    workbench(height: min(controlHeight, max(104, geometry.size.height * (keyboard ? 0.48 : 0.46))))
                }
            }.background(AppBackdrop())
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) { Text(session.projectName).font(.headline).lineLimit(1) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重新连接此会话") { directFocus = false; model.stop(); model.connect(client) }
                    Button("连接详情") { details = true }
                    Button("自定义 Micro 按钮") { customizingMicro = true }
                    if session.mode != "generic" { Button("原生增强、附件与记录") { model.stop(); directFocus = false; enhancements = true } }
                    Button(collapsed ? "显示控制栏" : "隐藏控制栏") { collapse() }
                    if !attempted.isEmpty && attempted != draft {
                        Button("将上次填入副本追加到草稿") { draft += (draft.isEmpty ? "" : "\n") + attempted; switchMode(.text); direct = false }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
            }
        }
        .sheet(isPresented: $enhancements, onDismiss: { if shown && phase == .active && !model.uncertain { model.connect(client) } }) {
            NavigationStack { ChatView(session: session, availableSessions: [session], nativeOnly: true).toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回终端") { enhancements = false } } } }
        }
        .sheet(isPresented: $details) {
            NavigationStack {
                Form {
                    LabeledContent("Agent", value: session.displayName)
                    LabeledContent("项目", value: session.projectName)
                    LabeledContent("终端", value: session.name)
                    LabeledContent("终端窗格编号", value: model.paneID ?? "不可用")
                    if let grid = model.grid { LabeledContent("终端网格", value: "\(grid.cols) × \(grid.rows)") }
                    Text("手机与 Mac 共用同一个会话，两边的输入都会发送到这里。")
                    Toggle("终端尺寸跟随手机", isOn: $followSize)
                    Text("开启后调整同一 tmux 窗口的排版；关闭或断开后恢复。多窗格保留分屏。")
                }.appList().navigationTitle("连接详情").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("完成") { details = false } }
            }
        }
        .sheet(isPresented: $customizingMicro) {
            NavigationStack {
                MicroCustomization().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { customizingMicro = false } }
                }
            }
        }
        .alert("使用系统听写", isPresented: $dictationHint) {
            Button("知道了") { dictationHintSeen = true; draftFocus = true }
        } message: { Text("点击系统键盘上的麦克风开始听写。文字会保留在本地草稿，由你决定何时发送。") }
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
            shown = true
            model.setFollowSize(followSize)
            draft = UserDefaults.standard.string(forKey: draftKey) ?? ""
            attempted = UserDefaults.standard.string(forKey: draftKey + ".attempted") ?? ""
            shortcuts = Array((UserDefaults.standard.stringArray(forKey: draftKey + ".shortcuts") ?? []).prefix(6))
            #if DEBUG
            if InterfacePreview.enabled { loadPreview(); return }
            #endif
            model.connect(client)
        }
        .onDisappear { shown = false; resumeOnActive = false; saveDraft(); model.stop() }
        .onChange(of: draft) { _, _ in
            saveDraft()
            if draftFocus { model.returnToCursor?() }
        }
        .onChange(of: draftFocus) { _, focused in if focused { model.returnToCursor?() } }
        .onChange(of: directFocus) { _, focused in if focused { model.returnToCursor?() } }
        .onChange(of: phase) { _, value in
            if value == .background {
                resumeOnActive = shown && !enhancements && (model.active || model.connecting) && !model.uncertain
                model.stop(); directFocus = false
            } else if value == .active && resumeOnActive && shown && !enhancements {
                resumeOnActive = false
                if !model.uncertain { model.connect(client) }
            }
        }
        .onChange(of: followSize) { _, value in model.setFollowSize(value) }
        .onChange(of: model.active) { _, value in if !value { directFocus = false } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false; directFocus = false }
    }
    private var controlHeight: CGFloat {
        if mode == .text { return direct ? (keyboard ? 148 : 196) : (keyboard ? 204 : 232) }
        return keyboard ? 192 : 260
    }
    private var targetBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.active ? theme.accent : theme.warning).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.displayName) · \(session.projectName)").font(.caption.weight(.semibold)).lineLimit(1)
                Text(model.status).font(.caption2).foregroundStyle(model.uncertain ? theme.warning : theme.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !model.active { Button("重试连接") { model.connect(client) }.font(.caption).frame(minWidth: 44, minHeight: 44).disabled(model.connecting) }
            if keyboard { Button { draftFocus = false; directFocus = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 44, height: 44) }.accessibilityLabel("收起键盘") }
        }.padding(.horizontal, 16).frame(minHeight: 44)
    }
    private func workbench(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Menu {
                    ForEach(availableSessions.filter { $0.key != session.key }) { target in
                        NavigationLink(value: target) { Text(target.projectName + " · " + target.displayName) }
                    }
                    if availableSessions.count < 2 { Text("暂无其他会话") }
                } label: { Image(systemName: "rectangle.stack").frame(width: 44, height: 44) }
                    .accessibilityLabel("切换会话")
                ForEach(WorkbenchMode.allCases, id: \.self) { item in
                    Button { switchMode(item) } label: {
                        VStack(spacing: 2) { Image(systemName: item.icon); Text(item.rawValue) }.font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(minHeight: 44)
                            .foregroundStyle(mode == item ? theme.accent : theme.secondary)
                            .background(mode == item ? theme.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityAddTraits(mode == item ? .isSelected : [])
                }
                Button { model.returnToCursor?() } label: { Image(systemName: "arrow.down.to.line").frame(width: 44, height: 44) }
                    .accessibilityLabel("回到当前输入位置")
                Button { collapse() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("隐藏控制栏")
            }.padding(.horizontal, 6)
            ScrollView {
                Group {
                    switch mode { case .text: textPanel; case .micro: microPanel; case .glide: glidePanel }
                }.frame(maxWidth: .infinity, minHeight: max(60, height - 54))
            }.scrollIndicators(.hidden).padding(.horizontal, 10).padding(.bottom, 8)
        }.frame(height: height).appGlass(radius: 24).padding(.horizontal, 10).padding(.vertical, 8)
    }
    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("输入方式", selection: Binding(get: { direct }, set: { value in
                direct = value; draftFocus = !value; directFocus = value
            })) {
                Text("本地草稿").tag(false)
                Text("终端直输").tag(true)
            }.pickerStyle(.segmented).frame(minHeight: 44)
            if direct {
                if !keyboard {
                    Text(model.canWrite ? "正在输入到终端" : "连接后可直接输入").font(.caption2).foregroundStyle(theme.warning)
                }
                TerminalKeyboard(enabled: model.canWrite, keepKeyboard: model.active && model.resizing, focused: $directFocus, commit: { text in
                    if text.contains("\n") && text != "\n" { model.paste(text, confirmed: true) }
                    else { model.committed(text) }
                }, key: { model.key($0) }, onInput: { model.returnToCursor?() })
                .frame(height: 44).background(theme.elevated.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                if !keyboard { Text("点按此处唤起键盘；回车就是 Enter").font(.caption2).foregroundStyle(theme.secondary).onTapGesture { directFocus = true } }
            } else {
                TextField("输入、粘贴或使用键盘听写…", text: $draft, axis: .vertical)
                    .focused($draftFocus).lineLimit(1...3).font(.body)
                    .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44)
                    .background(theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("此会话的本地草稿")
                HStack {
                    Menu {
                        Button("添加文件") { importing = true }
                        Button("添加照片") { photoPicker = true }
                    } label: { Image(systemName: uploading ? "arrow.up.doc" : "paperclip").frame(width: 44, height: 44) }
                    .disabled(uploading || client.paired == nil).accessibilityLabel("上传附件并加入草稿")
                    Button { beginDictation() } label: {
                        Image(systemName: "mic").frame(width: 44, height: 44)
                    }.accessibilityLabel("打开键盘听写到草稿")
                    Spacer(minLength: 4)
                    Button { appendDraft() } label: {
                        Label(attempted == draft && !draft.isEmpty ? "再次填入" : "填入终端", systemImage: "text.insert")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 44)
                            .background(theme.accent.opacity(0.14), in: Capsule())
                    }.disabled(!model.canWrite || model.writing || draft.isEmpty)
                }
                if !keyboard { Text("追加到终端输入位置 · 保留草稿副本").font(.caption2).foregroundStyle(theme.secondary) }
            }
        }
    }
    private var microPanel: some View {
            VStack(spacing: 5) {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 4) {
                    Button { customizingMicro = true } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                    }.accessibilityLabel("自定义 Micro 按钮")
                    Menu {
                        ForEach(availableSessions.filter { $0.key != session.key }) { target in
                            Button {
                                if shortcuts.contains(target.key) { shortcuts.removeAll { $0 == target.key } }
                                else if shortcuts.count < 6 { shortcuts.append(target.key) }
                                UserDefaults.standard.set(shortcuts, forKey: draftKey + ".shortcuts")
                            } label: { Label(target.projectName + " · " + target.displayName, systemImage: shortcuts.contains(target.key) ? "checkmark.circle.fill" : "circle") }
                            .disabled(!shortcuts.contains(target.key) && shortcuts.count >= 6)
                        }
                    } label: { Image(systemName: "rectangle.stack.badge.plus").frame(width: 44, height: 44) }.accessibilityLabel("配置最多六个会话快捷键")
                    ForEach(Array(availableSessions.filter { $0.key != session.key && shortcuts.contains($0.key) }.prefix(6))) { target in
                        NavigationLink(value: target) { Text(target.projectName.prefix(5)).font(.caption2).lineLimit(1).frame(minWidth: 44, minHeight: 44).appGlass(radius: 12, interactive: true) }
                    }
                    Menu {
                        ForEach(MicroAction.allCases.filter { $0.key != nil }) { action in
                            Button(action.accessibilityLabel) { performMicro(action) }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .disabled(!model.canWrite).accessibilityLabel("所有终端按键")
                } }
                let actions = MicroLayout.decode(storedMicroLayout)
                if actions.isEmpty {
                    Button("添加 Micro 按钮") { customizingMicro = true }.frame(minHeight: 44)
                } else {
                    Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                        ForEach(Array(stride(from: 0, to: actions.count, by: 4)), id: \.self) { start in
                            GridRow {
                                ForEach(Array(actions[start..<min(start + 4, actions.count)].enumerated()), id: \.element.id) { offset, action in
                                    let span = action == .dictation && start + offset == actions.count - 1 ? 4 - offset : 1
                                    microButton(action).gridCellColumns(span)
                                }
                                let lastIsWide = actions.last == .dictation
                                if start + 4 > actions.count && !lastIsWide {
                                    ForEach(0..<(4 - actions.count % 4), id: \.self) { _ in
                                        Color.clear.frame(height: 44).gridCellUnsizedAxes(.horizontal)
                                    }
                                }
                            }
                        }
                    }
                }
            }
    }
    private func microButton(_ action: MicroAction) -> some View {
        Button { performMicro(action) } label: {
            Group {
                if action == .dictation { Label(action.title, systemImage: "mic") }
                else { Text(action.title) }
            }.font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity).frame(minHeight: 44)
        }.buttonStyle(MicroKeyStyle()).disabled(action.key != nil && !model.canWrite)
            .accessibilityLabel(action.accessibilityLabel)
    }
    private func performMicro(_ action: MicroAction) {
        if let key = action.key { sendKey(key) }
        else { controlFeedback(); beginDictation() }
    }
    private func controlFeedback() {
        if haptics { feedback.selectionChanged(); feedback.prepare() }
    }
    private func sendKey(_ key: String) {
        if model.key(key) { controlFeedback() }
    }
    private func keyButton(_ title: String, _ key: String) -> some View {
        Button { sendKey(key) } label: { Text(title).font(.system(size: 13, weight: .medium, design: .monospaced)).frame(minWidth: 44, minHeight: 44) }
            .buttonStyle(MicroKeyStyle()).disabled(!model.canWrite).accessibilityLabel(key)
    }
    private var glidePanel: some View {
        VStack(spacing: 6) {
            Picker("手势含义", selection: $arrows) { Text("浏览").tag(false); Text("方向键").tag(true) }.pickerStyle(.segmented)
                .disabled(glideMeaning != nil)
            ZStack {
                RoundedRectangle(cornerRadius: 17).fill(theme.elevated.opacity(0.45))
                VStack(spacing: 8) { Image(systemName: arrows ? "arrow.up.and.down.and.arrow.left.and.right" : "viewfinder").font(.title2); Text(arrows ? "滑动发送方向键 · 不会确认" : "移动手机视口 · 不向 Mac 输入").font(.caption2) }.foregroundStyle(theme.secondary).allowsHitTesting(false)
            }.frame(minHeight: 90).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 8).onChanged { value in
                if glideMeaning == nil {
                    glideMeaning = arrows; lastDrag = .zero; browseMoved = false
                    if haptics { feedback.prepare() }
                }
                let dx = value.translation.width - lastDrag.width, dy = value.translation.height - lastDrag.height
                if glideMeaning == true {
                    guard Date().timeIntervalSince(lastArrow) >= 0.12, max(abs(dx), abs(dy)) >= 20 else { return }
                    let accepted = model.key(abs(dx) > abs(dy) ? (dx > 0 ? "Right" : "Left") : (dy > 0 ? "Down" : "Up"))
                    if accepted && haptics { feedback.selectionChanged(); feedback.prepare() }
                    lastArrow = Date(); lastDrag = value.translation
                } else {
                    if model.browse?(-dx, -dy) == true {
                        if !browseMoved && haptics { feedback.selectionChanged() }
                        browseMoved = true
                    }
                    lastDrag = value.translation
                }
            }.onEnded { _ in
                let browsing = glideMeaning == false && browseMoved
                model.cancelNavigation(); lastDrag = .zero; glideMeaning = nil; browseMoved = false
                if browsing { hideForBrowsing() }
            })
            HStack { keyButton("Esc", "Escape"); Spacer(); keyButton("Enter", "Enter") }
        }
    }
    private func appendDraft() {
        guard !draft.isEmpty, !model.writing, model.paste(draft, confirmed: true) else { return }
        attempted = draft; saveDraft()
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
    private func collapse() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { collapsed.toggle() }
        draftFocus = false; directFocus = false; model.cancelNavigation()
        if collapsed { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    }
    private func hideForBrowsing() {
        guard autoHide, !collapsed, !keyboard, !draftFocus, !directFocus else { return }
        collapse()
    }
    private func beginDictation() {
        switchMode(.text); direct = false; draftFocus = true
        if !dictationHintSeen { dictationHint = true }
    }
    private func switchMode(_ next: WorkbenchMode) {
        model.cancelNavigation(); glideMeaning = nil; lastDrag = .zero
        draftFocus = false; directFocus = false; mode = next; collapsed = false
    }
    #if DEBUG
    private func loadPreview() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--preview-hidden") { collapsed = true }
        if args.contains("--preview-text") || args.contains("--preview-keyboard") { mode = .text }
        if args.contains("--preview-micro") { mode = .micro }
        if args.contains("--preview-glide") { mode = .glide }
        draft = "请检查输入焦点切换，保留 Mac 上已有草稿。"
        model.preview()
        if args.contains("--preview-keyboard") { draftFocus = true }
    }
    #endif
}
private struct MicroKeyStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(theme.text)
            .frame(maxWidth: .infinity).appGlass(radius: 14, interactive: true)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.text.opacity(configuration.isPressed ? 0.2 : 0.07), lineWidth: 1))
            .shadow(color: theme.background.opacity(0.35), radius: configuration.isPressed ? 0 : 2, y: configuration.isPressed ? 0 : 2)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
    }
}
extension View { fileprivate func workbenchGlass(radius: CGFloat = 16) -> some View { appGlass(radius: radius) } }
