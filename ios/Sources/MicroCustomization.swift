import SwiftUI

struct MicroCustomization: View {
    @Environment(\.appTheme) private var theme
    @AppStorage(MicroLayout.storageKey) private var storedLayout = MicroLayout.defaultValue
    @AppStorage("terminalHaptics") private var haptics = true
    private var actions: [MicroAction] { MicroLayout.decode(storedLayout) }
    private var hidden: [MicroAction] { MicroAction.allCases.filter { !actions.contains($0) } }

    var body: some View {
        List {
            Section {
                ForEach(actions) { action in
                    HStack(spacing: 12) {
                        Text(action.title).font(.system(.callout, design: .monospaced)).frame(width: 62)
                        Text(action.accessibilityLabel).font(.callout)
                    }.frame(minHeight: 44)
                }
                .onDelete { indices in
                    var next = actions; next.remove(atOffsets: indices); save(next)
                }
                .onMove { source, destination in
                    var next = actions; next.move(fromOffsets: source, toOffset: destination); save(next)
                }
                if actions.isEmpty { Text("从下方添加常用按钮").foregroundStyle(theme.secondary) }
            } header: { Text("显示的按钮") } footer: {
                Text("拖动右侧手柄调整顺序，点减号隐藏按钮。设置适用于所有会话，并自动保存。")
            }.listRowBackground(theme.surface)
            if !hidden.isEmpty {
                Section("添加按钮") {
                    ForEach(hidden) { action in
                        Button { save(actions + [action]) } label: {
                            HStack {
                                Text(action.title).font(.system(.callout, design: .monospaced)).frame(width: 62)
                                Text(action.accessibilityLabel).font(.callout)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(theme.accent)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("添加" + action.accessibilityLabel)
                    }
                }.listRowBackground(theme.surface)
            }
            Section {
                Toggle("控制栏触觉反馈", isOn: $haptics)
                Button("恢复默认按钮") { save(MicroLayout.defaults) }
            } footer: { Text("触觉反馈适用于 Micro 按钮与滑控，表示手机已接受操作。") }
                .listRowBackground(theme.surface)
        }.appList().navigationTitle("自定义 Micro").navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
    }
    private func save(_ actions: [MicroAction]) { storedLayout = MicroLayout.encode(actions) }
}
