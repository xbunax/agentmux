import Foundation

enum MicroAction: String, CaseIterable, Identifiable {
    case escape = "Escape", up = "Up", tab = "Tab", enter = "Enter"
    case left = "Left", down = "Down", right = "Right", backspace = "BSpace"
    case backTab = "BTab", space = "Space", dictation = "dictation"
    case delete = "DC", home = "Home", end = "End", pageUp = "PPage", pageDown = "NPage"
    case interrupt = "C-c", endOfInput = "C-d"

    var id: String { rawValue }
    var key: String? { self == .dictation ? nil : rawValue }
    var title: String {
        switch self {
        case .escape: return "Esc"
        case .up: return "↑"
        case .tab: return "Tab"
        case .enter: return "Enter"
        case .left: return "←"
        case .down: return "↓"
        case .right: return "→"
        case .backspace: return "⌫"
        case .backTab: return "⇧Tab"
        case .space: return "Space"
        case .dictation: return "听写"
        case .delete: return "Del"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "PgUp"
        case .pageDown: return "PgDn"
        case .interrupt: return "Ctrl-C"
        case .endOfInput: return "Ctrl-D"
        }
    }
    var accessibilityLabel: String {
        switch self {
        case .escape: return "Escape，退出"
        case .up: return "上方向键"
        case .tab: return "Tab，补全"
        case .enter: return "Enter，回车"
        case .left: return "左方向键"
        case .down: return "下方向键"
        case .right: return "右方向键"
        case .backspace: return "退格"
        case .backTab: return "Shift-Tab"
        case .space: return "空格"
        case .dictation: return "听写到本地草稿"
        case .delete: return "向后删除"
        case .home: return "Home，行首"
        case .end: return "End，行尾"
        case .pageUp: return "向上翻页"
        case .pageDown: return "向下翻页"
        case .interrupt: return "Ctrl-C，中断信号"
        case .endOfInput: return "Ctrl-D，结束输入"
        }
    }
}

enum MicroLayout {
    static let storageKey = "terminalMicroLayout.v1"
    static let defaults: [MicroAction] = [.escape, .up, .tab, .enter, .left, .down, .right, .backspace, .backTab, .space, .dictation]
    static let defaultValue = encode(defaults)

    static func decode(_ value: String) -> [MicroAction] {
        guard let data = value.data(using: .utf8), let names = try? JSONDecoder().decode([String].self, from: data) else { return defaults }
        var seen = Set<MicroAction>()
        return names.compactMap { name in
            guard let action = MicroAction(rawValue: name), seen.insert(action).inserted else { return nil }
            return action
        }
    }
    static func encode(_ actions: [MicroAction]) -> String {
        let data = try! JSONEncoder().encode(actions.map(\.rawValue))
        return String(decoding: data, as: UTF8.self)
    }
}
