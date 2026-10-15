import SwiftUI
import UniformTypeIdentifiers

struct SSHConnectionSheet: View {
    @EnvironmentObject var client: Client
    @Environment(\.dismiss) var dismiss
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var usePrivateKey = false
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var hostKey: String?
    @State private var error: String?
    @State private var busy = false
    @State private var completed = false
    @State private var importing = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "desktopcomputer.and.arrow.down").font(.largeTitle).foregroundStyle(AppTheme.accent)
                        Text("连接你的 Mac").font(.title2.weight(.semibold))
                        Text("登录后自动发现 AgentMux，让手机接上正在进行的工作。").font(.subheadline).foregroundStyle(AppTheme.secondary)
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
                Section("Mac SSH") {
                    TextField("IP 地址或主机名", text: $host)
                        .keyboardType(.URL).textContentType(.URL)
                    TextField("SSH 端口", text: $port).keyboardType(.numberPad)
                    TextField("用户名", text: $username).textContentType(.username)
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(busy || hostKey != nil)

                Section("登录方式") {
                    Picker("登录方式", selection: $usePrivateKey) {
                        Text("密码").tag(false)
                        Text("SSH 私钥").tag(true)
                    }.pickerStyle(.segmented)
                    if usePrivateKey {
                        Button("导入私钥文件") { importing = true }
                        TextEditor(text: $privateKey).font(.caption.monospaced()).frame(minHeight: 100)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("私钥密码（可选）", text: $passphrase)
                        Text("支持 OpenSSH Ed25519 / RSA 私钥。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        SecureField("SSH 密码", text: $password).textContentType(.password)
                    }
                }.disabled(busy)

                if let hostKey {
                    Section("确认 SSH 主机") {
                        Text("首次连接，请核对 Mac 的 SSH 主机指纹。确认后将自动发现并连接 AgentMux 服务。")
                        Text(sshFingerprint(hostKey)).font(.caption.monospaced()).textSelection(.enabled)
                        Button("更换主机") { self.hostKey = nil; error = nil }.disabled(busy)
                    }
                }

                Section {
                    Button {
                        startConnection()
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text(busy ? "正在连接并发现服务…" : (hostKey == nil ? "连接 SSH" : "信任主机并连接"))
                        }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(busy || !validInput).opacity(validInput ? 1 : 0.5)
                    Text("Mac 需开启远程登录并运行 agentmuxd。SSH 登录凭据和设备凭据保存在此 iPhone 的钥匙串中。").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
            .appList()
            .navigationTitle("添加 Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() } }
            .onDisappear {
                operation?.cancel()
                password = ""; privateKey = ""; passphrase = ""
                if !completed { Task { await client.ssh.disconnect() } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 else {
                        throw SSHConnectionError.message("私钥文件不能超过 64 KiB")
                    }
                    privateKey = try String(contentsOf: url, encoding: .utf8)
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private var cleanHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validInput: Bool {
        !cleanHost.isEmpty && cleanHost.count <= 253 && !cleanUsername.isEmpty &&
        (Int(port).map { (1...65535).contains($0) } ?? false) &&
        (usePrivateKey ? !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !password.isEmpty)
    }

    private func startConnection() {
        guard validInput, let port = Int(port) else { return }
        busy = true; error = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                if let hostKey {
                    let login = usePrivateKey ? SSHLogin(privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines), passphrase: passphrase) : SSHLogin(password: password)
                    try await client.connectSSH(host: cleanHost, port: port, username: cleanUsername, hostKey: hostKey, login: login)
                    try Task.checkCancellation()
                    completed = true
                    dismiss()
                } else {
                    let discovered = try await client.ssh.inspectHost(host: cleanHost, port: port)
                    try Task.checkCancellation()
                    hostKey = discovered
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                await client.ssh.disconnect()
            }
        }
    }
}
