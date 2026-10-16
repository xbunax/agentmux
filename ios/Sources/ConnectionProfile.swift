import Foundation

struct IrohAddress: Codable, Equatable, Sendable {
    let endpointID: String
    let relayURL: String?
    let addresses: [String]
    let relayURLs: [String]?
}

/// Optional iroh metadata keeps all previously saved SSH profiles decodable.
struct PairedMac: Codable, Equatable, Sendable {
    let host: String
    let port: Int
    let username: String
    let hostKey: String
    let credential: String
    let deviceID: String
    var sshLogin: SSHLogin? = nil
    var apiPort: Int? = nil
    var iroh: IrohAddress? = nil
    var transportTitle: String { iroh == nil ? "SSH" : "iroh" }
    var connectionTitle: String { iroh == nil ? username + " · SSH" : "iroh · 扫码配对" }
    var draftIdentity: String {
        if let iroh { return "iroh:" + iroh.endpointID }
        return "\(host):\(port):\(username):\(hostKey)"
    }
}

struct ConnectionStore: Codable {
    var selectedID: String?
    var profiles: [PairedMac]
    var selected: PairedMac? { profiles.first { $0.deviceID == selectedID } }
}
struct TransportResponse: Sendable { let status: Int; let data: Data }
typealias SSHResponse = TransportResponse

/// Closing one terminal stream must leave concurrent file/API requests intact.
struct TerminalStream: Sendable {
    let frames: AsyncThrowingStream<Data, Error>
    private let cancel: @Sendable () -> Void
    init(frames: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void) {
        self.frames = frames; self.cancel = cancel
    }
    func close() { cancel() }
}

protocol AgentTransport: Sendable {
    func request(profile: PairedMac, path: String, method: String, token: String, body: Data?) async throws -> TransportResponse
    func terminalStream(profile: PairedMac, generation: String) async throws -> TerminalStream
    func disconnect() async
}
