import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum AppTheme {
    static let background = Color.adaptive(light: 0xF3F5F7, dark: 0x10151D)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x1A222E)
    static let elevated = Color.adaptive(light: 0xE9EEF2, dark: 0x242F3E)
    static let chat = Color.adaptive(light: 0xE9F0F2, dark: 0x0F1923)
    static let outgoing = Color.adaptive(light: 0xDBF3E7, dark: 0x24564C)
    static let accent = Color.adaptive(light: 0x14745B, dark: 0x79DBB7)
    static let text = Color.adaptive(light: 0x18232F, dark: 0xE9EFF6)
    static let secondary = Color.adaptive(light: 0x5B6C7C, dark: 0xA5B4C4)
    static let line = Color.adaptive(light: 0xDCE3E8, dark: 0x303D4D)
    static let warning = Color.adaptive(light: 0x986114, dark: 0xF1C27B)

    static func provider(_ command: String) -> Color {
        switch command {
        case "claude": return .adaptive(light: 0xA85737, dark: 0xE8AF8B)
        case "pi": return .adaptive(light: 0x7161B5, dark: 0xB8A7ED)
        default: return accent
        }
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
    let command: String
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().fill(AppTheme.provider(command).opacity(0.15))
            if command == "claude" {
                Image(systemName: "sun.max.fill").font(.system(size: size * 0.44, weight: .medium))
            } else if command == "pi" {
                Text("π").font(.system(size: size * 0.6, weight: .medium, design: .serif))
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size * 0.35, weight: .semibold))
            }
        }.foregroundStyle(AppTheme.provider(command)).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let title: String
    var color: Color = AppTheme.accent
    var symbol: String = "circle.fill"
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium)).labelStyle(.titleAndIcon)
            .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.1), in: Capsule())
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.secondary)
            Spacer()
            if !detail.isEmpty { Text(detail).font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondary) }
        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
    }
}

struct SearchBox: View {
    @Binding var text: String
    var placeholder = "搜索"
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondary)
            TextField(placeholder, text: $text).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(AppTheme.secondary) }
                    .frame(minWidth: 32, minHeight: 44).accessibilityLabel("清空搜索")
            }
        }.padding(.horizontal, 13).frame(minHeight: 44)
            .background(AppTheme.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 13))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 48)
            .foregroundStyle(AppTheme.background).background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
                .foregroundStyle(AppTheme.accent).frame(width: 78, height: 78)
                .background(AppTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(AppTheme.text)
            Text(detail).font(.subheadline).foregroundStyle(AppTheme.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.vertical, 40)
    }
}

extension View {
    func appPanel() -> some View {
        background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.line.opacity(0.55), lineWidth: 0.5))
    }
    func appList() -> some View {
        scrollContentBackground(.hidden).background(AppTheme.background)
            .tint(AppTheme.accent)
    }
}
