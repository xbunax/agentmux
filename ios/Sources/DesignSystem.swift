import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum ColorPalette: String, CaseIterable, Identifiable {
    case agentmux, gruvbox, catppuccin, nord, solarized
    var id: String { rawValue }
    var title: String {
        switch self {
        case .agentmux: return "AgentMux"
        case .gruvbox: return "Gruvbox"
        case .catppuccin: return "Catppuccin"
        case .nord: return "Nord"
        case .solarized: return "Solarized"
        }
    }
    var detail: String {
        switch self {
        case .agentmux: return "青绿 · 原生"
        case .gruvbox: return "暖色 · Light / Dark"
        case .catppuccin: return "粉彩 · Latte / Mocha"
        case .nord: return "冷灰蓝 · 浅色为适配版"
        case .solarized: return "蓝绿 · Light / Dark"
        }
    }
    // bg, surface, text, secondary, accent, warning, error, ANSI blue, magenta, cyan.
    func colors(dark: Bool) -> [UInt32] {
        switch (self, dark) {
        case (.agentmux, false): return [0xF3F5F7,0xFFFFFF,0x18232F,0x5B6C7C,0x14745B,0x986114,0xBA3745,0x2868A8,0x7161B5,0x147D8C]
        case (.agentmux, true): return [0x10151D,0x1A222E,0xE9EFF6,0xA5B4C4,0x79DBB7,0xF1C27B,0xF08B93,0x83B6EE,0xB8A7ED,0x80CED8]
        case (.gruvbox, false): return [0xFBF1C7,0xEBDBB2,0x3C3836,0x665C54,0x427B58,0xB57614,0x9D0006,0x076678,0x8F3F71,0x427B58]
        case (.gruvbox, true): return [0x282828,0x3C3836,0xEBDBB2,0xBDAE93,0xB8BB26,0xFABD2F,0xFB4934,0x83A598,0xD3869B,0x8EC07C]
        case (.catppuccin, false): return [0xEFF1F5,0xE6E9EF,0x4C4F69,0x6C6F85,0x8839EF,0x9B660E,0xD20F39,0x1E66F5,0xEA76CB,0x179299]
        case (.catppuccin, true): return [0x1E1E2E,0x313244,0xCDD6F4,0xBAC2DE,0xCBA6F7,0xF9E2AF,0xF38BA8,0x89B4FA,0xF5C2E7,0x94E2D5]
        case (.nord, false): return [0xECEFF4,0xE5E9F0,0x2E3440,0x4C566A,0x456A83,0x91672F,0xA34451,0x5E81AC,0x8C6085,0x39777D]
        case (.nord, true): return [0x2E3440,0x3B4252,0xECEFF4,0xD8DEE9,0x88C0D0,0xEBCB8B,0xBF616A,0x81A1C1,0xB48EAD,0x8FBCBB]
        case (.solarized, false): return [0xFDF6E3,0xEEE8D5,0x586E75,0x657B83,0x007E80,0x947100,0xDC322F,0x268BD2,0x6C71C4,0x2AA198]
        case (.solarized, true): return [0x002B36,0x073642,0x93A1A1,0x839496,0x2AA198,0xB58900,0xDC322F,0x268BD2,0x6C71C4,0x2AA198]
        }
    }
    func ansi(dark: Bool) -> [UInt32] {
        switch self {
        case .gruvbox:
            return [0x282828,0xCC241D,0x98971A,0xD79921,0x458588,0xB16286,0x689D6A,0xA89984] + (dark
                ? [0x928374,0xFB4934,0xB8BB26,0xFABD2F,0x83A598,0xD3869B,0x8EC07C,0xEBDBB2]
                : [0x928374,0x9D0006,0x79740E,0xB57614,0x076678,0x8F3F71,0x427B58,0xFBF1C7])
        case .solarized:
            return [0x073642,0xDC322F,0x859900,0xB58900,0x268BD2,0xD33682,0x2AA198,0xEEE8D5,0x002B36,0xCB4B16,0x586E75,0x657B83,0x839496,0x6C71C4,0x93A1A1,0xFDF6E3]
        default:
            let c = colors(dark: dark)
            let green: UInt32 = self == .catppuccin ? (dark ? 0xA6E3A1 : 0x40A02B) : self == .nord ? 0xA3BE8C : c[4]
            let basic = [c[0],c[6],green,c[5],c[7],c[8],c[9],c[2]]
            return basic + [c[3]] + Array(basic.dropFirst())
        }
    }
}

struct AppTheme: Equatable {
    var palette: ColorPalette = .agentmux
    private func color(_ index: Int) -> Color {
        .adaptive(light: palette.colors(dark: false)[index], dark: palette.colors(dark: true)[index])
    }
    var background: Color { color(0) }
    var surface: Color { color(1) }
    var elevated: Color { color(1) }
    var chat: Color { color(0) }
    var outgoing: Color { accent.opacity(0.14) }
    var accent: Color { color(4) }
    var text: Color { color(2) }
    var secondary: Color { color(3) }
    var line: Color { color(3).opacity(0.3) }
    var warning: Color { color(5) }
    var error: Color { color(6) }
    var success: Color { .adaptive(light: 0x357A45, dark: 0xA6D89C) }
    func provider(_ command: String) -> Color { command == "claude" ? warning : command == "pi" ? color(8) : accent }
}
private struct AppThemeKey: EnvironmentKey { static let defaultValue = AppTheme() }
extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension Color {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func channels(_ value: UInt32) -> (Double, Double, Double) {
            (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
        }
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let (r, g, b) = channels(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = channels(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

struct AgentAvatar: View {
    @Environment(\.appTheme) private var theme
    let command: String
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().fill(theme.provider(command).opacity(0.15))
            if command == "claude" {
                Image(systemName: "sun.max.fill").font(.system(size: size * 0.44, weight: .medium))
            } else if command == "pi" {
                Text("π").font(.system(size: size * 0.6, weight: .medium, design: .serif))
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size * 0.35, weight: .semibold))
            }
        }.foregroundStyle(theme.provider(command)).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    @Environment(\.appTheme) private var theme
    let title: String
    var color: Color? = nil
    var symbol: String = "circle.fill"
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium)).labelStyle(.titleAndIcon)
            .foregroundStyle(color ?? theme.accent).padding(.horizontal, 9).padding(.vertical, 5)
            .background((color ?? theme.accent).opacity(0.1), in: Capsule())
    }
}

struct SectionHeading: View {
    @Environment(\.appTheme) private var theme
    let title: String
    var detail: String = ""
    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.secondary)
            Spacer()
            if !detail.isEmpty { Text(detail).font(.caption.monospacedDigit()).foregroundStyle(theme.secondary) }
        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
    }
}

struct SearchBox: View {
    @Environment(\.appTheme) private var theme
    @Binding var text: String
    var placeholder = "搜索"
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.secondary)
            TextField(placeholder, text: $text).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.secondary) }
                    .frame(minWidth: 32, minHeight: 44).accessibilityLabel("清空搜索")
            }
        }.padding(.horizontal, 13).frame(minHeight: 44)
            .appGlass(radius: 24)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 48)
            .foregroundStyle(theme.text).appGlass(radius: 14, interactive: true)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct EmptyState: View {
    @Environment(\.appTheme) private var theme
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.accent).frame(width: 78, height: 78)
                .background(theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(theme.text)
            Text(detail).font(.subheadline).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.vertical, 40)
    }
}

struct AppBackdrop: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        LinearGradient(colors: [theme.background, theme.background, theme.surface.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            .background(theme.background).ignoresSafeArea()
    }
}
struct GlassSurface: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var solid
    var radius: CGFloat = 18
    var interactive = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if solid { shape.fill(theme.surface) }
            else if #available(iOS 26.0, *) {
                shape.fill(theme.surface.opacity(0.25))
                    .glassEffect(.regular.tint(theme.accent.opacity(0.035)).interactive(interactive), in: shape)
            } else {
                shape.fill(.regularMaterial).overlay(shape.fill(theme.surface.opacity(0.25)))
            }
        }
    }
}
private struct AppListStyle: ViewModifier {
    @Environment(\.appTheme) private var theme
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(AppBackdrop()).tint(theme.accent)
            .listStyle(.insetGrouped).listSectionSpacing(24)
            .listRowSeparatorTint(theme.line.opacity(0.6))
    }
}
extension View {
    func appPanel() -> some View { appGlass() }
    func appGlass(radius: CGFloat = 18, interactive: Bool = false) -> some View {
        background(GlassSurface(radius: radius, interactive: interactive))
    }
    func appList() -> some View { modifier(AppListStyle()) }
}
