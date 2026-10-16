import Foundation

/// Runs the exact iOS transport against the Rust daemon, with no model calls.
func testIrohTransport(path: String) async throws {
    let code = try IrohPairCode.parse(String(contentsOfFile: path, encoding: .utf8))
    let transport = IrohTransport()
    try await transport.setIdentity(Data(repeating: 42, count: 32))
    let profile = try await transport.pair(code, name: "Swift iroh probe")
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw IrohError.message(message) }
    }
    func request(_ path: String, _ method: String = "GET", _ body: Data? = nil) async throws -> TransportResponse {
        try await transport.request(profile: profile, path: path, method: method, token: profile.credential, body: body)
    }
    let settings = try await request("/v1/settings")
    try check(settings.status == 200, "Settings failed")
    var legacySettings = try JSONSerialization.jsonObject(with: settings.data) as! [String: Any]
    legacySettings.removeValue(forKey: "iroh")
    let savedSettings = try await request("/v1/settings", "PUT", JSONSerialization.data(withJSONObject: legacySettings))
    try check(savedSettings.status == 200, "Legacy settings update failed")
    let preserved = try JSONSerialization.jsonObject(with: savedSettings.data) as! [String: Any]
    try check((preserved["iroh"] as? [String: Any])?["enabled"] as? Bool == true, "Legacy client disabled iroh")
    print("PASS: Swift official SDK ↔ Rust iroh pairing and API")
    var reuseRejected = false
    do { _ = try await transport.pair(code, name: "reuse") } catch { reuseRejected = true }
    try check(reuseRejected, "Ticket accepted twice")
    let wrongToken = try await transport.request(profile: profile, path: "/v1/settings", method: "GET", token: String(repeating: "0", count: 64), body: nil)
    try check(wrongToken.status == 401, "Wrong token accepted")
    let impostor = IrohTransport()
    try await impostor.setIdentity(Data(repeating: 43, count: 32))
    var wrongPeerRejected = false
    do { _ = try await impostor.request(profile: profile, path: "/v1/settings", method: "GET", token: profile.credential, body: nil) }
    catch { wrongPeerRejected = true }
    await impostor.disconnect()
    try check(wrongPeerRejected, "Stolen token accepted from another endpoint")
    let forbidden = try await request("/v1/devices", "POST", Data("{\"name\":\"forbidden\"}".utf8))
    try check(forbidden.status == 403, "Device elevated privileges")
    let roots = try JSONSerialization.jsonObject(with: settings.data) as! [String: Any]
    let directory = roots["default_directory"] as! String
    func filePath(_ path: String) -> String {
        var uri = URLComponents(); uri.path = "/v1/file"; uri.queryItems = [URLQueryItem(name: "path", value: path)]
        return uri.string!
    }
    let bytes = Data("中文🙂 terminal\n".utf8) + Data(repeating: 37, count: 140000)
    let file = filePath(directory + "/iroh-probe.bin")
    try check(try await request(file, "PUT", bytes).status == 201, "File upload failed")
    let downloaded = try await request(file)
    try check(downloaded.status == 200 && downloaded.data == bytes, "File bytes changed across chunk boundaries")
    let escaped = try await request(filePath("/etc/passwd"))
    try check(escaped.status == 403, "Path confinement failed")
    await transport.disconnect()
    try check(try await request("/v1/settings").status == 200, "Saved-profile reconnect failed")
    if let pane = ProcessInfo.processInfo.environment["AGENTMUX_IROH_PANE"] {
        var paneURI = URLComponents(); paneURI.path = "/v1/terminal/panes/\(pane)/open"
        let opened = try await request(paneURI.string!, "POST", Data("{\"generic\":true}".utf8))
        try check(opened.status == 200, "Terminal open failed")
        let object = try JSONSerialization.jsonObject(with: opened.data) as! [String: Any]
        let generation = object["generation"] as! String
        let stream = try await transport.terminalStream(profile: profile, generation: generation)
        var iterator = stream.frames.makeAsyncIterator()
        let ready = try await iterator.next()!
        try check(String(decoding: ready, as: UTF8.self).contains("ready"), "Terminal stream not ready")
        let body = try JSONSerialization.data(withJSONObject: ["kind": "paste", "text": "iroh-中文", "sequence": 1, "request_id": UUID().uuidString])
        try check(try await request("/v1/terminal/streams/\(generation)/input", "POST", body).status == 200, "Terminal input failed")
        stream.close()
        try check(try await request("/v1/settings").status == 200, "Closing terminal broke API")
        _ = try await request("/v1/terminal/streams/\(generation)", "DELETE")
        print("PASS: terminal stream, Unicode input, independent stream cancellation")
    }
    let revoked = try await request("/v1/devices/\(profile.deviceID)", "DELETE")
    try check(revoked.status == 204, "Revocation failed")
    try await Task.sleep(for: .milliseconds(500))
    var revokedRejected = false
    do { _ = try await request("/v1/settings") } catch { revokedRejected = true }
    try check(revokedRejected, "Revoked connection survived")
    await transport.disconnect()
    print("PASS: one-use pairing, peer-bound credential, file confinement, reconnect, revocation")
}
