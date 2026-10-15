import Foundation

/// Uses the exact transport source compiled into the iOS app; never prints credentials.
@main struct SSHProbe {
    static func main() async throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTMUX_PAIR_JSON"] else {
            throw NSError(domain: "SSHProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Set AGENTMUX_PAIR_JSON to a fresh QR payload file"])
        }
        let code = try JSONDecoder().decode(PairCode.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let transport = SSHTransport()
        let bootstrap = PairedMac(host: code.host, port: code.port, username: code.username, hostKey: code.hostKey, credential: code.ticket, deviceID: "bootstrap")
        let body = try JSONEncoder().encode(["ticket": code.ticket, "name": "Swift Transport Probe"])
        let pairing = try await transport.request(profile: bootstrap, path: "/v1/pair/complete", method: "POST", token: "", body: body)
        guard pairing.status == 200 else { throw URLError(.userAuthenticationRequired) }
        let result = try JSONDecoder().decode([String: String].self, from: pairing.data)
        guard let token = result["token"], let id = result["device_id"] else { throw URLError(.cannotParseResponse) }
        await transport.disconnect()
        let profile = PairedMac(host: code.host, port: code.port, username: code.username, hostKey: code.hostKey, credential: token, deviceID: id)
        let settings = try await transport.request(profile: profile, path: "/v1/settings", method: "GET", token: token, body: nil)
        guard settings.status == 200 else { throw URLError(.badServerResponse) }
        let revoke = try await transport.request(profile: profile, path: "/v1/devices/\(id)", method: "DELETE", token: token, body: nil)
        guard revoke.status == 204 else { throw URLError(.badServerResponse) }
        await transport.disconnect()
        print("PASS: iOS Citadel transport source → Rust SSH: pinned host key, QR exchange, reconnect, HTTP forwarding, revocation")
    }
}
