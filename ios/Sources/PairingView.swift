import SwiftUI
import CryptoKit

struct PairingStatus: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject var client: Client
    var manage = true
    @State private var connectingSSH = false
    @State private var forget = false
    @State private var details = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let mac = client.paired {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(theme.accent)
                        .frame(width: 44, height: 44).background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mac.host).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text).lineLimit(1)
                        Text(mac.username + " · SSH").font(.caption).foregroundStyle(theme.secondary)
                    }
                    Spacer(minLength: 4)
                    StatusBadge(title: client.isConnected ? "已连接" : "已保存", color: client.isConnected ? theme.accent : theme.secondary)
                }
                if manage {
                    DisclosureGroup("连接详情", isExpanded: $details) {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("SSH 端口", value: String(mac.port))
                            Text(sshFingerprint(mac.hostKey)).font(.caption.monospaced()).textSelection(.enabled)
                            Text("主机密钥已固定，凭据保存在此设备的钥匙串。").font(.caption).foregroundStyle(theme.secondary)
                        }.padding(.top, 8)
                    }.font(.subheadline)
                    Button("移除此 Mac", role: .destructive) { forget = true }.font(.subheadline).frame(minHeight: 44)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: -8) {
                        AgentAvatar(command: "codex", size: 48)
                        AgentAvatar(command: "claude", size: 48)
                        AgentAvatar(command: "pi", size: 48)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你的 Agent，随时在线").font(.title2.weight(.semibold)).foregroundStyle(theme.text)
                        Text("连接 Mac，在手机上继续对话、查看进展和确认操作。").font(.subheadline).foregroundStyle(theme.secondary)
                    }
                    Button { connectingSSH = true } label: { Label("连接 Mac", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
                    Label("通过 SSH 加密连接", systemImage: "lock.shield").font(.caption).foregroundStyle(theme.secondary)
                }.padding(.vertical, 8)
            }
        }.padding(16).appPanel()
            .sheet(isPresented: $connectingSSH) { SSHConnectionSheet() }
            .confirmationDialog("移除此 Mac 的设备凭据并断开连接？", isPresented: $forget) {
                Button("移除并断开", role: .destructive) { Task { await client.forget() } }
            }
    }
}

func sshFingerprint(_ key: String) -> String {
    let pieces = key.split(separator: " ")
    guard pieces.count >= 2, let data = Data(base64Encoded: String(pieces[1])) else { return "无效主机公钥" }
    return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
}
