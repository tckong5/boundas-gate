import XCTest
@testable import C2CManager

final class MockConnectionProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, headers, data) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class ConnectionDiagnosticsTests: XCTestCase {
    func testSharedSidePathsRemainDistinctAndRejectAliases() {
        let origin = "https://mac.example.ts.net"
        let side = origin + "/side/abcdef123456"
        XCTAssertEqual(EndpointAddress.mcpURL(side), side + "/mcp")
        XCTAssertEqual(EndpointAddress.publicBase(side + "/mcp")?.absoluteString, side)
        XCTAssertEqual(EndpointAddress.mcpURL(origin), origin + "/mcp")
        for path in ["/side/other/mcp", "/side/abcdef123456/../mcp", "/side/abcdef123456/admin", "/side/abcdef123456/mcp/extra"] {
            XCTAssertNil(EndpointAddress.mcpURL(origin + path))
        }
    }
    func testTransportFailureExposesTypedSystemVPNDiagnosticAndHealthySkipsDetection() async {
        let base = "https://gate.example.ts.net"
        var failPublic = true, commands = 0
        MockConnectionProtocol.respond = { request in
            if failPublic && request.url?.host == "gate.example.ts.net" { throw URLError(.cannotConnectToHost) }
            if request.url!.path.hasSuffix("/health") {
                return (200, [:], Data("{\"service\":\"c2c-bridge\",\"workspaceId\":\"\(self.workspaceID)\",\"status\":\"ok\"}".utf8))
            }
            return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"\(base)/.well-known/oauth-protected-resource/mcp\""], Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockConnectionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let network = SystemTailscaleVPN(command: { _, args in
            commands += 1
            return .init(code: 0, output: args.contains("list")
                ? "* (Connected) 653460BD-8619-4BC4-9EDD-7FB5658CF3BE VPN (io.tailscale.ipn.macsys) \"Tailscale\""
                : "ip_address: 100.71.254.85")
        })
        let checker = ConnectionChecker(session: session, systemVPN: network)
        let failed = await checker.check(workspaceID: workspaceID, status: status(publicURL: base, tunnelURL: base))
        XCTAssertEqual(failed.systemTailscaleInterception?.hostname, "gate.example.ts.net")
        XCTAssertEqual(commands, 2)
        failPublic = false
        let healthy = await checker.check(workspaceID: workspaceID, status: status(publicURL: base, tunnelURL: base))
        XCTAssertTrue(healthy.isUsable)
        XCTAssertNil(healthy.systemTailscaleInterception)
        XCTAssertEqual(commands, 2)
    }
    func testGatewayHealthRequiresGatewayServiceIdentity() async {
        let stable = "https://mac.example.ts.net/c2c/abcdef123456"
        MockConnectionProtocol.respond = { request in
            if request.url!.path.hasSuffix("/health") {
                return (200, [:], Data("{\"service\":\"boundas-gateway\",\"workspaceId\":\"abcdef123456\",\"status\":\"ok\"}".utf8))
            }
            return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"\(stable)/.well-known/oauth-protected-resource/mcp\""], Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockConnectionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let checker = ConnectionChecker(session: session, systemVPN: .init(command: { _, _ in .init(code: 0, output: "") }))
        let status = status(publicURL: stable, tunnelURL: stable)
        let gatewayResult = await checker.check(workspaceID: "abcdef123456", status: status, service: "boundas-gateway")
        let bridgeResult = await checker.check(workspaceID: "abcdef123456", status: status)
        XCTAssertTrue(gatewayResult.isUsable)
        XCTAssertFalse(bridgeResult.isUsable)
    }
    func testStableWorkspaceURLPreservesPrefixAndRejectsOtherPaths() {
        let base = "https://mac.example.ts.net/c2c/abcdef123456"
        XCTAssertEqual(EndpointAddress.mcpURL(base), base + "/mcp")
        XCTAssertEqual(EndpointAddress.mcpURL(base + "/mcp/"), base + "/mcp")
        XCTAssertEqual(EndpointAddress.publicBase(base + "/mcp")?.absoluteString, base)
        XCTAssertNil(EndpointAddress.publicBase(base + "/admin"))
        XCTAssertNil(EndpointAddress.mcpURL("https://mac.example.ts.net/c2c/../../mcp"))
    }

    func testStableConnectionUsesWorkspacePrefixForHealthAndOAuth() async {
        let stable = "https://mac.example.ts.net/c2c/abcdef123456"
        let result = await check(status: status(publicURL: stable, tunnelURL: stable)) { request in
            let remote = request.url!.host != "127.0.0.1"
            if request.url!.path.hasSuffix("/health") {
                XCTAssertEqual(request.url!.path, remote ? "/c2c/abcdef123456/health" : "/health")
                return (200, [:], Data("{\"service\":\"c2c-bridge\",\"workspaceId\":\"\(self.workspaceID)\",\"status\":\"ok\"}".utf8))
            }
            XCTAssertEqual(request.url!.path, remote ? "/c2c/abcdef123456/mcp" : "/mcp")
            return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"\(stable)/.well-known/oauth-protected-resource/mcp\""], Data())
        }
        XCTAssertTrue(result.isUsable)
    }

    func testExistingWorkspaceConfigDefaultsToCloudflare() throws {
        let record = try JSONDecoder().decode(WorkspaceRecord.self, from: Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Test\",\"path\":\"/tmp/test\",\"c2cID\":\"abcdef123456\"}".utf8))
        XCTAssertEqual(record.provider, .cloudflare)
    }

    private let base = "https://current.trycloudflare.com"
    private let workspaceID = "canto-worktree"

    private func status(publicURL: String? = nil, tunnelURL: String? = nil) -> WorkspaceStatus {
        .init(running: true, state: "running", reason: nil, port: 49347, pid: 123,
              publicUrl: publicURL ?? base, tunnel: .init(running: true, url: tunnelURL ?? base),
              tokenCount: 3, pairingActive: false)
    }

    private func check(status: WorkspaceStatus? = nil,
                       fixture: @escaping (URLRequest) throws -> (Int, [String: String], Data)) async -> ConnectionDiagnostics {
        MockConnectionProtocol.respond = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockConnectionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await ConnectionChecker(session: session, systemVPN: .init(command: { _, _ in .init(code: 0, output: "") })).check(workspaceID: workspaceID, status: status ?? self.status())
    }

    private func healthy(_ request: URLRequest) -> (Int, [String: String], Data) {
        if request.url!.path == "/health" {
            return (200, [:], Data("{\"service\":\"c2c-bridge\",\"workspaceId\":\"\(workspaceID)\",\"status\":\"ok\"}".utf8))
        }
        return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"\(base)/.well-known/oauth-protected-resource/mcp\""], Data())
    }

    func testHealthyEndpointAcceptsUnauthorizedMCPAndUsesWorkspacePort() async {
        let result = await check { request in
            if request.url!.host == "127.0.0.1" { XCTAssertEqual(request.url!.port, 49347) }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url!.path == "/mcp" { XCTAssertEqual(request.httpMethod, "POST") }
            return self.healthy(request)
        }
        XCTAssertTrue(result.isUsable)
    }

    func testRunningProcessWithDeadPublicTunnelIsUnusable() async {
        let result = await check { request in
            request.url!.host == "current.trycloudflare.com" ? (503, [:], Data()) : self.healthy(request)
        }
        XCTAssertTrue(result.bridge.passed)
        XCTAssertTrue(result.localMCP.passed)
        XCTAssertEqual(result.publicEndpoint.state, .failed)
        XCTAssertFalse(result.isUsable)
    }

    func testPublicEndpointPointingAtDifferentWorkspaceIsRejected() async {
        let result = await check { request in
            if request.url!.host == "current.trycloudflare.com", request.url!.path == "/health" {
                return (200, [:], Data(#"{"service":"c2c-bridge","workspaceId":"original-fixture-folder","status":"ok"}"#.utf8))
            }
            return self.healthy(request)
        }
        XCTAssertEqual(result.publicEndpoint.state, .failed)
        XCTAssertFalse(result.isUsable)
    }

    func testLocalPortBelongingToDifferentWorkspaceIsRejected() async {
        let result = await check { request in
            if request.url!.host == "127.0.0.1", request.url!.path == "/health" {
                return (200, [:], Data(#"{"service":"c2c-bridge","workspaceId":"original-fixture-folder","status":"ok"}"#.utf8))
            }
            return self.healthy(request)
        }
        XCTAssertEqual(result.bridge.state, .failed)
        XCTAssertFalse(result.isUsable)
    }

    func testStaleOAuthMetadataFailsDespiteHealthyBridgeAndPublicEndpoint() async {
        let result = await check { request in
            if request.url!.path == "/mcp" {
                return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"https://old.trycloudflare.com/.well-known/oauth-protected-resource/mcp\""], Data())
            }
            return self.healthy(request)
        }
        XCTAssertTrue(result.bridge.passed)
        XCTAssertTrue(result.publicEndpoint.passed)
        XCTAssertEqual(result.localMCP.state, .failed)
        XCTAssertEqual(result.publicMCP.state, .failed)
        XCTAssertFalse(result.isUsable)
    }

    func testBridgeAndTunnelURLMismatchFails() async {
        let result = await check(status: status(tunnelURL: "https://other.trycloudflare.com"), fixture: healthy)
        XCTAssertEqual(result.address.state, .failed)
        XCTAssertFalse(result.isUsable)
    }

    func testUnexpectedUnauthenticatedSuccessFails() async {
        let result = await check { request in
            request.url!.path == "/mcp" ? (200, [:], Data()) : self.healthy(request)
        }
        XCTAssertEqual(result.localMCP.state, .failed)
        XCTAssertFalse(result.isUsable)
    }

    func testMissingOAuthMetadataFails() async {
        let result = await check { request in
            request.url!.path == "/mcp" ? (401, [:], Data()) : self.healthy(request)
        }
        XCTAssertEqual(result.publicMCP.state, .failed)
        XCTAssertFalse(result.isUsable)
    }

    func testPublicDNSFailureDoesNotImplyLocalBridgeOrLoginFailure() async {
        for code in [URLError.Code.cannotFindHost, .dnsLookupFailed] {
            let result = await check { request in
                if request.url!.host == "current.trycloudflare.com" { throw URLError(code) }
                return self.healthy(request)
            }
            XCTAssertTrue(result.bridge.passed)
            XCTAssertTrue(result.localMCP.passed)
            XCTAssertTrue(result.publicEndpoint.isDNSFailure)
            XCTAssertTrue(result.hasPublicDNSFailure)
            XCTAssertFalse(result.isUsable)
        }
    }

    func testNetworkTimeoutFailsWithoutTrustingProcessState() async {
        let result = await check { request in
            if request.url!.host == "current.trycloudflare.com" { throw URLError(.timedOut) }
            return self.healthy(request)
        }
        XCTAssertTrue(result.bridge.passed)
        XCTAssertEqual(result.publicEndpoint.state, .failed)
        XCTAssertFalse(result.hasPublicDNSFailure)
        XCTAssertFalse(result.isUsable)
    }

    func testURLChangeRetainsConfirmedConnectorAndSurvivesSave() throws {
        var workspace = WorkspaceRecord(name: "Canto", path: "/tmp/canto", c2cID: workspaceID)
        workspace.observeMCPURL("https://old.trycloudflare.com/mcp")
        workspace.configuredMCPURL = workspace.lastObservedMCPURL
        workspace.observeMCPURL(base + "/mcp")
        let restored = try JSONDecoder().decode(WorkspaceRecord.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(restored.previousMCPURL, "https://old.trycloudflare.com/mcp")
        XCTAssertEqual(restored.configuredMCPURL, restored.previousMCPURL)
        XCTAssertEqual(restored.connectorState(currentURL: base + "/mcp"), .needsUpdate)
    }

    func testExistingConfigWithoutURLHistoryStillLoadsUnconfirmed() throws {
        let data = Data("{\"id\":\"\(UUID())\",\"name\":\"Canto\",\"path\":\"/tmp/canto\",\"c2cID\":\"\(workspaceID)\"}".utf8)
        let workspace = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertNil(workspace.configuredMCPURL)
        XCTAssertEqual(workspace.connectorState(currentURL: base + "/mcp"), .unconfirmed)
    }

    func testEquivalentServerURLsMatch() {
        var workspace = WorkspaceRecord(name: "Canto", path: "/tmp/canto", c2cID: workspaceID)
        workspace.configuredMCPURL = "https://CURRENT.trycloudflare.com:443/mcp/"
        XCTAssertEqual(workspace.connectorState(currentURL: base), .matches)
        XCTAssertNil(EndpointAddress.mcpURL("https://user:secret@example.com/mcp"))
        XCTAssertNil(EndpointAddress.mcpURL("https://example.com/mcp?secret=value"))
    }
}
