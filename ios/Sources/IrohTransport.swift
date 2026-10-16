import Foundation
import IrohLib

enum IrohError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct IrohPairCode: Codable, Sendable {
    let version: Int
    let transport: String
    let name: String
    let endpointID: String
    let relayURL: String?
    let addresses: [String]
    let relayURLs: [String]?
    let ticket: String
    let expires: UInt64
    enum CodingKeys: String, CodingKey {
        case version, transport, name, addresses, ticket, expires
        case endpointID = "endpoint_id", relayURL = "relay_url", relayURLs = "relay_urls"
    }
    var address: IrohAddress { IrohAddress(endpointID: endpointID, relayURL: relayURL, addresses: addresses, relayURLs: relayURLs) }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 8192 else { throw IrohError.message("配对码过长") }
        let code = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard code.version == 2, code.transport == "iroh", code.name.utf8.count <= 256,
              code.addresses.count <= 16, (code.relayURLs?.count ?? 0) <= 16,
              code.ticket.count == 64, code.ticket.allSatisfy({ $0.isHexDigit }),
              code.expires > UInt64(Date().timeIntervalSince1970) else {
            throw IrohError.message("配对码无效、已过期或版本不受支持，请在 Mac 上重新生成")
        }
        _ = try EndpointId.fromString(s: code.endpointID)
        for value in (code.relayURLs ?? []) + (code.relayURL.map { [$0] } ?? []) {
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme), url.host != nil else {
                throw IrohError.message("无效的中继地址")
            }
        }
        return code
    }
}

/// One API operation per QUIC stream. Failed writes are never replayed.
actor IrohTransport: AgentTransport {
    private var identity: Data?
    private var cached: (PairedMac, Endpoint, Connection)?
    private var pending: (UUID, PairedMac, Task<(Endpoint, Connection), Error>)?

    func setIdentity(_ key: Data) throws {
        guard key.count == 32 else { throw IrohError.message("无效的设备身份") }
        identity = key
    }
    private static func endpoint(_ address: IrohAddress, key: Data) async throws -> Endpoint {
        let mode: RelayMode?
        if let urls = address.relayURLs {
            if urls.isEmpty { mode = RelayMode.disabled() }
            else { mode = try RelayMode.customFromUrls(urls: urls) }
        } else { mode = nil }
        return try await Endpoint.bind(options: EndpointOptions(
            preset: address.relayURLs == [] ? presetMinimal() : presetN0(),
            secretKey: key, relayMode: mode))
    }
    private func connection(_ profile: PairedMac) async throws -> Connection {
        if let cached, cached.0 == profile, cached.2.closeReason() == nil { return cached.2 }
        if let pending, pending.1 == profile { return try await pending.2.value.1 }
        await disconnect()
        guard let address = profile.iroh, let identity else { throw IrohError.message("请重新扫码配对此 Mac") }
        let id = UUID()
        let task = Task { () throws -> (Endpoint, Connection) in
            let endpoint = try await Self.endpoint(address, key: identity)
            do {
                let connection = try await timed {
                    try await endpoint.connect(addr: EndpointAddr(id: EndpointId.fromString(s: address.endpointID), relayUrl: address.relayURL, addresses: address.addresses), alpn: Data("agentmux/api/1".utf8))
                }
                try Task.checkCancellation()
                return (endpoint, connection)
            } catch { try? await endpoint.close(); throw error }
        }
        pending = (id, profile, task)
        do {
            let (endpoint, connection) = try await task.value
            guard pending?.0 == id else { try? await endpoint.close(); throw CancellationError() }
            cached = (profile, endpoint, connection); pending = nil
            return connection
        } catch { if pending?.0 == id { pending = nil }; throw error }
    }
    func disconnect() async {
        let old = cached; cached = nil
        let connecting = pending; pending = nil
        connecting?.2.cancel()
        if let old { try? await old.1.close() }
    }
    func pathDescription() -> String {
        guard let connection = cached?.2, connection.closeReason() == nil else { return "iroh · 未连接" }
        let paths = connection.paths().filter { $0.isSelected }
        if paths.contains(where: { $0.isIp }) { return "iroh · 点对点直连" }
        if paths.contains(where: { $0.isRelay }) { return "iroh · 加密中继" }
        return "iroh · 正在探测路径"
    }
    func pair(_ code: IrohPairCode, name: String) async throws -> PairedMac {
        guard let identity else { throw IrohError.message("设备身份未准备好") }
        let endpoint = try await Self.endpoint(code.address, key: identity)
        do {
            let connection = try await timed {
                try await endpoint.connect(addr: EndpointAddr(id: EndpointId.fromString(s: code.endpointID), relayUrl: code.relayURL, addresses: code.addresses), alpn: Data("agentmux/pair/1".utf8))
            }
            let stream = try await connection.openBi()
            let header = try JSONSerialization.data(withJSONObject: ["version": 1, "ticket": code.ticket, "name": name])
            try await timed { try await writePacket(stream.send(), header); try await stream.send().finish() }
            let response = try await readResponse(stream.recv())
            guard response.status == 200 else { throw IrohError.message(String(decoding: response.data, as: UTF8.self)) }
            struct Enrollment: Decodable { let token: String; let device_id: String }
            let value = try JSONDecoder().decode(Enrollment.self, from: response.data)
            try? await endpoint.close()
            return PairedMac(host: code.name, port: 0, username: "", hostKey: code.endpointID, credential: value.token, deviceID: value.device_id, iroh: code.address)
        } catch { try? await endpoint.close(); throw error }
    }
    private func open(profile: PairedMac, path: String, method: String, token: String, body: Data?) async throws -> BiStream {
        guard (body?.count ?? 0) <= 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let connection = try await connection(profile)
        let stream = try await connection.openBi()
        do {
            let header = try JSONSerialization.data(withJSONObject: ["version": 1, "method": method, "path": path, "token": token, "length": body?.count ?? 0])
            guard header.count <= 8192 else { throw URLError(.dataLengthExceedsMaximum) }
            try await timed {
                try await writePacket(stream.send(), header)
                if let body { try await stream.send().writeAll(buf: body) }
                try await stream.send().finish()
            }
            return stream
        } catch { try? await stream.send().reset(errorCode: 1); throw error }
    }
    func request(profile: PairedMac, path: String, method: String, token: String, body: Data?) async throws -> TransportResponse {
        let stream = try await open(profile: profile, path: path, method: method, token: token, body: body)
        do { return try await readResponse(stream.recv()) }
        catch { try? await stream.recv().stop(errorCode: 1); throw error }
    }
    func terminalStream(profile: PairedMac, generation: String) async throws -> TerminalStream {
        guard UUID(uuidString: generation) != nil else { throw URLError(.badURL) }
        var uri = URLComponents(); uri.path = "/v1/terminal/streams/\(generation)"
        let stream = try await open(profile: profile, path: uri.string!, method: "GET", token: profile.credential, body: nil)
        let status = try await responseStatus(stream.recv())
        guard status == 200 else { try? await stream.recv().stop(errorCode: 1); throw IrohError.message("终端连接被拒绝（\(status)），请重新选择目标") }
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let reader = Task {
            do {
                var buffer = Data()
                while let chunk = try await readChunk(stream.recv()) {
                    buffer.append(chunk)
                    guard buffer.count <= 3 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        if !line.isEmpty, case .dropped = pair.continuation.yield(line) { throw IrohError.message("终端输出过快，请重新打开终端") }
                    }
                }
                guard buffer.isEmpty else { throw IrohError.message("终端输出不完整，请重新连接") }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
            try? await stream.recv().stop(errorCode: 0)
        }
        pair.continuation.onTermination = { _ in reader.cancel() }
        return TerminalStream(frames: pair.stream, cancel: { reader.cancel(); pair.continuation.finish() })
    }
}

private func timed<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: .seconds(20)); throw URLError(.timedOut) }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
private func writePacket(_ stream: SendStream, _ data: Data) async throws {
    var size = UInt32(data.count).bigEndian
    try await stream.writeAll(buf: withUnsafeBytes(of: &size) { Data($0) })
    try await stream.writeAll(buf: data)
}
private func readLength(_ stream: RecvStream) async throws -> Int {
    let data = try await timed { try await stream.readExact(size: 4) }
    return data.reduce(0) { ($0 << 8) | Int($1) }
}
private func responseStatus(_ stream: RecvStream) async throws -> Int {
    let size = try await readLength(stream)
    guard (1...8192).contains(size) else { throw URLError(.badServerResponse) }
    let data = try await timed { try await stream.readExact(size: UInt32(size)) }
    struct Header: Decodable { let status: Int }
    return try JSONDecoder().decode(Header.self, from: data).status
}
private func readChunk(_ stream: RecvStream) async throws -> Data? {
    let size = try await readLength(stream)
    if size == 0 { return nil }
    guard size <= 65536 else { throw URLError(.dataLengthExceedsMaximum) }
    return try await timed { try await stream.readExact(size: UInt32(size)) }
}
private func readResponse(_ stream: RecvStream) async throws -> TransportResponse {
    let status = try await responseStatus(stream)
    var data = Data()
    while let chunk = try await readChunk(stream) {
        guard data.count + chunk.count <= 16 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        data.append(chunk)
    }
    return TransportResponse(status: status, data: data)
}
