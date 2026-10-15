import SwiftUI
import CryptoKit

struct PairingStatus: View {
    @EnvironmentObject var client: Client
    @State private var connectingSSH = false
    @State private var forget = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let mac = client.paired {
                Label(mac.host, systemImage: "lock.shield.fill").foregroundStyle(.green)
                Text("SSH 加密 · 主机密钥已固定").font(.caption).foregroundStyle(.secondary)
                Button("断开并移除此设备", role: .destructive) { forget = true }
            } else {
                Text("登录 Mac 的 SSH，自动发现 AgentMux 和正在运行的 Agent。").font(.subheadline)
                Button { connectingSSH = true } label: {
                    Label("通过 SSH 连接 Mac", systemImage: "network")
                }.buttonStyle(.borderedProminent)
            }
        }
        .sheet(isPresented: $connectingSSH) { SSHConnectionSheet() }
        .confirmationDialog("移除此设备的 AgentMux 凭据并断开连接？", isPresented: $forget) {
            Button("移除并断开", role: .destructive) { Task { await client.forget() } }
        }
    }
}

func sshFingerprint(_ key: String) -> String {
    let pieces = key.split(separator: " ")
    guard pieces.count >= 2, let data = Data(base64Encoded: String(pieces[1])) else { return "无效主机公钥" }
    return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
}
