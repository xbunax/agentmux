import Foundation
import Citadel
import NIO
import NIOHTTP1
import NIOSSH
import Crypto

struct SSHLogin: Codable, Equatable, Sendable {
    var password: String?
    var privateKey: String?
    var passphrase: String?

    func authentication(username: String) throws -> @Sendable () -> SSHAuthenticationMethod {
        if let privateKey {
            guard privateKey.utf8.count <= 64 * 1024 else { throw SSHConnectionError.message("私钥不能超过 64 KiB") }
            let decryption = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            let type = try SSHKeyDetection.detectPrivateKeyType(from: privateKey)
            if type == .ed25519 {
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: privateKey, decryptionKey: decryption)
                return { .ed25519(username: username, privateKey: key) }
            }
            if type == .rsa {
                let key = try Insecure.RSA.PrivateKey(sshRsa: privateKey, decryptionKey: decryption)
                return { .rsa(username: username, privateKey: key) }
            }
            throw SSHConnectionError.message("请使用 OpenSSH Ed25519 或 RSA 私钥")
        }
        guard let password else { throw SSHConnectionError.message("请输入 SSH 密码或私钥") }
        return { .passwordBased(username: username, password: password) }
    }
}

enum SSHConnectionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class HostKeyProbe: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    var discoveredKey: String? { lock.lock(); defer { lock.unlock() }; return key }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        lock.lock(); key = String(openSSHPublicKey: hostKey); lock.unlock()
        // Stop before user authentication. Credentials are sent only after the user trusts this key.
        validationCompletePromise.fail(SSHConnectionError.message("等待确认 SSH 主机密钥"))
    }
}

struct PairCode: Codable {
    let version: Int
    let host: String
    let port: Int
    let username: String
    let hostKey: String
    let ticket: String
    let expires: UInt64
    enum CodingKeys: String, CodingKey {
        case version, host, port, username, ticket, expires
        case hostKey = "host_key"
    }
}
struct PairedMac: Codable, Equatable {
    let host: String
    let port: Int
    let username: String
    let hostKey: String
    let credential: String
    let deviceID: String
    var sshLogin: SSHLogin? = nil
    var apiPort: Int? = nil
}
struct SSHResponse: Sendable { let status: Int; let data: Data }
private final class ResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let promise: EventLoopPromise<SSHResponse>
    var status = 0
    var data = Data()
    var finished = false
    init(_ promise: EventLoopPromise<SSHResponse>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): status = Int(head.status.code)
        case .body(var buffer):
            guard self.data.count + buffer.readableBytes <= 16 * 1024 * 1024 else {
                errorCaught(context: context, error: URLError(.dataLengthExceedsMaximum)); return
            }
            self.data.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            guard !finished else { return }
            finished = true; promise.succeed(SSHResponse(status: status, data: self.data))
            context.close(promise: nil)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !finished { finished = true; promise.fail(error) }
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !finished { finished = true; promise.fail(URLError(.networkConnectionLost)) }
    }
}
actor SSHTransport {
    init() {
        NIOSSHAlgorithms.register(publicKey: Insecure.RSA.PublicKey.self, signature: Insecure.RSA.Signature.self)
    }
    private var active: SSHClient?
    private var profile: PairedMac?
    private var connecting: Task<SSHClient, Error>?
    func inspectHost(host: String, port: Int) async throws -> String {
        let probe = HostKeyProbe()
        var settings = SSHClientSettings(
            host: host, port: port,
            authenticationMethod: { .passwordBased(username: "", password: "") },
            hostKeyValidator: .custom(probe)
        )
        settings.connectTimeout = .seconds(15)
        do {
            let client = try await SSHClient.connect(to: settings)
            try? await client.close()
        } catch {
            if let key = probe.discoveredKey { return key }
            throw SSHConnectionError.message("无法连接 SSH 主机 \(host):\(port)。请检查地址、端口及 Mac 的远程登录设置。")
        }
        throw SSHConnectionError.message("无法读取 SSH 主机密钥")
    }

    func connectSSH(host: String, port: Int, username: String, hostKey: String, login: SSHLogin, deviceName: String) async throws -> PairedMac {
        let bootstrap = PairedMac(host: host, port: port, username: username, hostKey: hostKey, credential: "", deviceID: "pending", sshLogin: login)
        let client: SSHClient
        do { client = try await connection(bootstrap) }
        catch is InvalidHostKey {
            throw SSHConnectionError.message("SSH 主机密钥已变化，请核对 Mac 的主机指纹后重新连接。")
        } catch {
            throw SSHConnectionError.message("SSH 登录失败。请核对用户名、密码或私钥，并确认 Mac 已开启远程登录。")
        }
        let quotedName = "'" + deviceName.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = """
        discovery="${AGENTMUX_DISCOVERY:-$HOME/Library/Application Support/AgentMux/service.json}"
        if [ ! -r "$discovery" ]; then
          printf '%s\\n' 'AgentMux service not found. Start the updated agentmuxd on this Mac first.' >&2
          exit 1
        fi
        executable=$(/usr/bin/plutil -extract executable raw -o - "$discovery") || exit 1
        exec "$executable" connect \(quotedName)
        """
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)); try? await client.close() }
            catch {}
        }
        defer { timeout.cancel() }
        let output: ByteBuffer
        do { output = try await client.executeCommand(command, maxResponseSize: 16 * 1024) }
        catch {
            await disconnect()
            throw SSHConnectionError.message("SSH 已连接，但无法发现 AgentMux 服务。请在 Mac 启动更新后的 agentmuxd，并允许 SSH 命令执行及 TCP 转发。")
        }
        timeout.cancel()
        struct Enrollment: Decodable { let version: Int; let api_port: Int; let token: String; let device_id: String }
        let enrollment = try JSONDecoder().decode(Enrollment.self, from: Data(output.readableBytesView))
        guard enrollment.version == 1, (1...65535).contains(enrollment.api_port),
              enrollment.token.count >= 32, UUID(uuidString: enrollment.device_id) != nil else {
            throw SSHConnectionError.message("AgentMux 服务返回了无效的连接信息")
        }
        let mac = PairedMac(host: host, port: port, username: username, hostKey: hostKey, credential: enrollment.token, deviceID: enrollment.device_id, sshLogin: login, apiPort: enrollment.api_port)
        profile = mac
        let response = try await request(profile: mac, path: "/v1/settings", method: "GET", token: mac.credential, body: nil)
        guard response.status == 200 else { throw SSHConnectionError.message("AgentMux 服务校验失败，请重新连接") }
        return mac
    }
    func disconnect() async {
        connecting?.cancel(); connecting = nil
        let client = active; active = nil; profile = nil
        try? await client?.close()
    }
    private func connection(_ profile: PairedMac) async throws -> SSHClient {
        if self.profile == profile {
            if let active, active.isConnected { return active }
            if let connecting { return try await connecting.value }
        }
        await disconnect()
        self.profile = profile
        let task = Task {
            let key = try NIOSSHPublicKey(openSSHPublicKey: profile.hostKey)
            let authentication = try (profile.sshLogin ?? SSHLogin(password: profile.credential)).authentication(username: profile.username)
            var settings = SSHClientSettings(
                host: profile.host, port: profile.port,
                authenticationMethod: authentication,
                hostKeyValidator: .trustedKeys([key])
            )
            settings.connectTimeout = .seconds(15)
            return try await SSHClient.connect(to: settings)
        }
        connecting = task
        do {
            let client = try await task.value
            guard self.profile == profile, !Task.isCancelled else {
                try? await client.close()
                throw CancellationError()
            }
            active = client; connecting = nil; return client
        } catch {
            if self.profile == profile { connecting = nil }
            throw error
        }
    }
    func request(profile: PairedMac, path: String, method: String, token: String, body: Data?) async throws -> SSHResponse {
        let client = try await connection(profile)
        let apiPort = profile.apiPort ?? 9847
        let promise = client.eventLoop.makePromise(of: SSHResponse.self)
        let channel = try await client.createDirectTCPIPChannel(using: .init(
            targetHost: "127.0.0.1", targetPort: apiPort,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        )) { channel in
            channel.pipeline.addHTTPClientHandlers().flatMap {
                channel.pipeline.addHandler(ResponseHandler(promise))
            }
        }
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(30)) {
            channel.pipeline.fireErrorCaught(URLError(.timedOut))
        }
        defer { timeout.cancel(); channel.close(promise: nil) }
        try Task.checkCancellation()
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:\(apiPort)")
        headers.add(name: "Authorization", value: "Bearer \(token)")
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: String(body?.count ?? 0))
        let head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: method), uri: path, headers: headers)
        // A NIO write promise completes only after a flush. Queue all parts first;
        // awaiting an unflushed head would deadlock until the request timeout.
        try await channel.eventLoop.flatSubmit {
            channel.write(HTTPClientRequestPart.head(head), promise: nil)
            if let body { channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil) }
            return channel.writeAndFlush(HTTPClientRequestPart.end(nil))
        }.get()
        return try await withTaskCancellationHandler {
            try await promise.futureResult.get()
        } onCancel: {
            channel.close(promise: nil)
        }
    }
}

/// A single generation of terminal output. Cancellation closes its own forwarding
/// channel, not the shared SSH client used by files and native capabilities.
struct TerminalHTTPStream: @unchecked Sendable {
    let frames: AsyncThrowingStream<Data, Error>
    let channel: Channel
    func close() { channel.close(promise: nil) }
}
private final class TerminalResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var pending = Data()
    var accepted = false
    var ended = false
    var timeout: Scheduled<Void>?
    init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }
    func handlerAdded(context: ChannelHandlerContext) { armTimeout(context) }
    func armTimeout(_ context: ChannelHandlerContext) {
        timeout?.cancel()
        timeout = context.eventLoop.scheduleTask(in: .seconds(20)) { [weak self, weak channel = context.channel] in
            self?.continuation.finish(throwing: URLError(.timedOut))
            channel?.close(promise: nil)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        armTimeout(context)
        switch unwrapInboundIn(data) {
        case .head(let head):
            accepted = head.status == .ok
            if !accepted { errorCaught(context: context, error: SSHConnectionError.message("终端连接被拒绝（\(head.status.code)），请重新选择目标。")) }
        case .body(var buffer):
            guard accepted, !ended else { return }
            pending.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
            guard pending.count <= 3 * 1024 * 1024 else { errorCaught(context: context, error: URLError(.dataLengthExceedsMaximum)); return }
            while let end = pending.firstIndex(of: 10) {
                let frame = Data(pending[..<end]); pending.removeSubrange(...end)
                if case .dropped = continuation.yield(frame) {
                    errorCaught(context: context, error: SSHConnectionError.message("终端输出过快，已停止输入。请重新打开现场。")); return
                }
            }
        case .end:
            ended = true; timeout?.cancel(); continuation.finish(); context.close(promise: nil)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ended = true; timeout?.cancel(); continuation.finish(throwing: error); context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        timeout?.cancel()
        if !ended { continuation.finish(throwing: URLError(.networkConnectionLost)) }
    }
}
extension SSHTransport {
    func terminalStream(profile: PairedMac, generation: String) async throws -> TerminalHTTPStream {
        guard UUID(uuidString: generation) != nil else { throw URLError(.badURL) }
        let client = try await connection(profile)
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let port = profile.apiPort ?? 9847
        let channel = try await client.createDirectTCPIPChannel(using: .init(
            targetHost: "127.0.0.1", targetPort: port,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        )) { channel in
            channel.pipeline.addHTTPClientHandlers().flatMap {
                channel.pipeline.addHandler(TerminalResponseHandler(pair.continuation))
            }
        }
        pair.continuation.onTermination = { _ in channel.close(promise: nil) }
        do {
            try Task.checkCancellation()
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: "127.0.0.1:\(port)")
            headers.add(name: "Authorization", value: "Bearer \(profile.credential)")
            headers.add(name: "Connection", value: "close")
            let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/terminal/streams/\(generation)", headers: headers)
            try await channel.eventLoop.flatSubmit {
                channel.write(HTTPClientRequestPart.head(head), promise: nil)
                return channel.writeAndFlush(HTTPClientRequestPart.end(nil))
            }.get()
            return TerminalHTTPStream(frames: pair.stream, channel: channel)
        } catch { channel.close(promise: nil); throw error }
    }
}
