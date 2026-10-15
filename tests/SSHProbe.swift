import Foundation

/// Uses the exact transport source compiled into the iOS app; never prints credentials.
@main struct SSHProbe {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        if let host = ProcessInfo.processInfo.environment["AGENTMUX_SSH_HOST"] {
            try await testSSHLogin(host: host)
            return
        }
        guard let path = ProcessInfo.processInfo.environment["AGENTMUX_PAIR_JSON"] else {
            throw NSError(domain: "SSHProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Set AGENTMUX_PAIR_JSON to a fresh QR payload file"])
        }
        let code = try JSONDecoder().decode(PairCode.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let transport = SSHTransport()
        let bootstrap = PairedMac(host: code.host, port: code.port, username: code.username, hostKey: code.hostKey, credential: code.ticket, deviceID: "bootstrap")
        let body = try JSONEncoder().encode(["ticket": code.ticket, "name": "Swift Transport Probe"])
        FileHandle.standardError.write(Data("QR probe: exchange ticket\n".utf8))
        let pairing = try await transport.request(profile: bootstrap, path: "/v1/pair/complete", method: "POST", token: "", body: body)
        guard pairing.status == 200 else { throw URLError(.userAuthenticationRequired) }
        let result = try JSONDecoder().decode([String: String].self, from: pairing.data)
        guard let token = result["token"], let id = result["device_id"] else { throw URLError(.cannotParseResponse) }
        await transport.disconnect()
        let profile = PairedMac(host: code.host, port: code.port, username: code.username, hostKey: code.hostKey, credential: token, deviceID: id)
        FileHandle.standardError.write(Data("QR probe: reconnect with device credential\n".utf8))
        let settings = try await transport.request(profile: profile, path: "/v1/settings", method: "GET", token: token, body: nil)
        guard settings.status == 200 else { throw URLError(.badServerResponse) }
        let revoke = try await transport.request(profile: profile, path: "/v1/devices/\(id)", method: "DELETE", token: token, body: nil)
        guard revoke.status == 204 else { throw URLError(.badServerResponse) }
        await transport.disconnect()
        print("PASS: iOS Citadel transport source → Rust SSH: pinned host key, QR exchange, reconnect, HTTP forwarding, revocation")
    }

    static func testSSHLogin(host: String) async throws {
        let env = ProcessInfo.processInfo.environment
        let port = Int(env["AGENTMUX_SSH_PORT"]!)!
        let expectedKey = env["AGENTMUX_SSH_HOST_KEY"]!
        let transport = SSHTransport()
        FileHandle.standardError.write(Data("SSH probe: inspect host key\n".utf8))
        let key = try await transport.inspectHost(host: host, port: port)
        guard key == expectedKey else { throw URLError(.serverCertificateUntrusted) }
        let login: SSHLogin
        if let path = env["AGENTMUX_SSH_PRIVATE_KEY"] {
            login = SSHLogin(privateKey: try String(contentsOfFile: path, encoding: .utf8), passphrase: env["AGENTMUX_SSH_PASSPHRASE"])
        } else {
            login = SSHLogin(password: env["AGENTMUX_SSH_PASSWORD"]!)
        }
        FileHandle.standardError.write(Data("SSH probe: authenticate and enroll\n".utf8))
        if env["AGENTMUX_SSH_EXPECT_FAILURE"] != nil {
            var rejected = false
            do { _ = try await transport.connectSSH(host: host, port: port, username: "test-user", hostKey: key, login: login, deviceName: "Denied probe") }
            catch { rejected = true }
            await transport.disconnect()
            guard rejected else { throw SSHConnectionError.message("Invalid login or missing service was accepted") }
            print("PASS: invalid SSH login / missing service rejected")
            return
        }
        let profile = try await transport.connectSSH(host: host, port: port, username: "test-user", hostKey: key, login: login, deviceName: "Swift ' SSH $(false) probe")
        // Stored QR profiles from previous releases must remain decodable.
        let old = Data("{\"host\":\"localhost\",\"port\":9848,\"username\":\"agentmux\",\"hostKey\":\"unused\",\"credential\":\"unused\",\"deviceID\":\"unused\"}".utf8)
        guard try JSONDecoder().decode(PairedMac.self, from: old).sshLogin == nil else { throw URLError(.cannotParseResponse) }
        let stored = try JSONDecoder().decode(PairedMac.self, from: JSONEncoder().encode(profile))
        await transport.disconnect()
        FileHandle.standardError.write(Data("SSH probe: reconnect and verify device access\n".utf8))
        let response = try await transport.request(profile: stored, path: "/v1/settings", method: "GET", token: stored.credential, body: nil)
        guard response.status == 200 else { throw URLError(.badServerResponse) }
        let listing = try await transport.request(profile: stored, path: "/v1/devices", method: "GET", token: stored.credential, body: nil)
        let devices = try JSONSerialization.jsonObject(with: listing.data) as! [[String: Any]]
        guard devices.contains(where: { $0["id"] as? String == stored.deviceID && $0["name"] as? String == "Swift ' SSH $(false) probe" }) else { throw URLError(.cannotParseResponse) }
        let denied = try await transport.request(profile: stored, path: "/v1/devices", method: "POST", token: stored.credential, body: Data("{\"name\":\"unauthorized\"}".utf8))
        guard denied.status == 403 else { throw URLError(.badServerResponse) }
        let revoked = try await transport.request(profile: stored, path: "/v1/devices/\(stored.deviceID)", method: "DELETE", token: stored.credential, body: nil)
        guard revoked.status == 204 else { throw URLError(.badServerResponse) }
        let rejected = try await transport.request(profile: stored, path: "/v1/settings", method: "GET", token: stored.credential, body: nil)
        guard rejected.status == 401 else { throw URLError(.badServerResponse) }
        await transport.disconnect()
        // A mismatched host key must fail before authentication or enrollment.
        let changed = PairedMac(host: stored.host, port: stored.port, username: stored.username, hostKey: env["AGENTMUX_SSH_WRONG_KEY"]!, credential: stored.credential, deviceID: stored.deviceID, sshLogin: login)
        var rejectedHostKey = false
        do {
            _ = try await transport.request(profile: changed, path: "/v1/settings", method: "GET", token: stored.credential, body: nil)
        } catch { rejectedHostKey = true }
        guard rejectedHostKey else { throw SSHConnectionError.message("Host-key mismatch was accepted") }
        await transport.disconnect()
        print("PASS: normal SSH login → automatic discovery/enrollment → forwarding → saved-profile reconnect → revocation; host-key mismatch rejected")
    }
}
