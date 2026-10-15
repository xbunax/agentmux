import Foundation
import Citadel
import NIO
import NIOHTTP1
import NIOSSH

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
    private var active: SSHClient?
    private var profile: PairedMac?
    private var connecting: Task<SSHClient, Error>?
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
            var settings = SSHClientSettings(
                host: profile.host, port: profile.port,
                authenticationMethod: { .passwordBased(username: profile.username, password: profile.credential) },
                hostKeyValidator: .trustedKeys([key])
            )
            settings.connectTimeout = .seconds(15)
            return try await SSHClient.connect(to: settings)
        }
        connecting = task
        do {
            let client = try await task.value
            active = client; connecting = nil; return client
        } catch { connecting = nil; throw error }
    }
    func request(profile: PairedMac, path: String, method: String, token: String, body: Data?) async throws -> SSHResponse {
        let client = try await connection(profile)
        let promise = client.eventLoop.makePromise(of: SSHResponse.self)
        let channel = try await client.createDirectTCPIPChannel(using: .init(
            targetHost: "127.0.0.1", targetPort: 9847,
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
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:9847")
        headers.add(name: "Authorization", value: "Bearer \(token)")
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: String(body?.count ?? 0))
        let head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: method), uri: path, headers: headers)
        // A NIO write promise completes only after a flush. Queue all parts first;
        // awaiting an unflushed head would deadlock until the request timeout.
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        if let body { channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil) }
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
        return try await promise.futureResult.get()
    }
}
