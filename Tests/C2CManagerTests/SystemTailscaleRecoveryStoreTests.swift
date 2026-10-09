import XCTest
@testable import C2CManager

@MainActor
private final class VPNFixtureClient: GatewayClient {
    var calls: [String] = []
    var stopped = false
    var candidateURL: String? = "https://gate.example.ts.net/mcp"
    var failureKind = "transient"
    var failureStep = "health"
    var failureCode = "NETWORK_ERROR"
    var failureStatus: Int?
    func gateway(_ action: String, input: Data?, sourceID: String?) async throws -> Data {
        calls.append(action)
        if stopped {
            var body: [String: Any] = ["running": false, "state": "stopped", "gatewayID": "012345abc678", "tokenCount": 1, "pairingActive": false, "roots": [], "endpointMigrationPending": true, "transport": "external", "transportSetup": ["state": "ready", "message": "Fixture ready"]]
            body["endpointMigrationCandidateURL"] = candidateURL
            var detail: [String: Any] = ["step": failureStep, "kind": failureKind, "code": failureCode]
            detail["status"] = failureStatus
            body["endpointMigrationFailureDetail"] = detail
            return try JSONSerialization.data(withJSONObject: body)
        }
        return Data(#"{"running":true,"state":"running","gatewayID":"012345abc678","port":12345,"publicUrl":"https://gate.example.ts.net","tunnel":{"running":true,"url":"https://gate.example.ts.net"},"tokenCount":1,"pairingActive":false,"roots":[],"endpointMigrationPending":true}"#.utf8)
    }
}

@MainActor
final class SystemTailscaleRecoveryStoreTests: XCTestCase {
    func testCleanedCandidateMigrationInterceptionAndConfirmedRecovery() async throws {
        let client = VPNFixtureClient(); client.stopped = true
        let id = "653460BD-8619-4BC4-9EDD-7FB5658CF3BE"
        var connected = true, stopCalls = 0
        let network = SystemTailscaleVPN(command: { _, args in
            if args == ["--nc", "stop", id] { connected = false; stopCalls += 1; return .init(code: 0, output: "") }
            if args.contains("list") {
                return .init(code: 0, output: "* (\(connected ? "Connected" : "Disconnected")) \(id) VPN (io.tailscale.ipn.macsys) \"Tailscale\"")
            }
            return .init(code: 0, output: "ip_address: 100.71.254.85")
        }, settle: {})
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedGatewayStore(automaticallyRefresh: false, client: client, connectionCheck: { _, _, _ in
            let pending = ConnectionCheck.pending("Candidate stopped")
            return .init(checkedAt: .now, bridge: pending, localMCP: pending, publicEndpoint: pending, publicMCP: pending, address: pending)
        }, diagnosticsLogFile: directory.appendingPathComponent("log"), systemVPN: network)
        await store.refresh()
        XCTAssertEqual(store.status?.running, false)
        XCTAssertNil(store.diagnostics?.systemTailscaleInterception)
        XCTAssertEqual(store.migrationInterception?.hostname, "gate.example.ts.net")
        XCTAssertEqual(store.connectionTitle, "Tailscale VPN is intercepting this Gate")
        XCTAssertFalse(store.connectionHint.contains("cache"))
        let action = SecureAccessPresentation.make(status: store.status, complete: false, message: nil,
            diagnostics: store.diagnostics, interception: store.systemTailscaleInterception).action
        XCTAssertEqual(action, .disconnectSystemTailscale)
        await store.disconnectSystemTailscale(confirmed: true, network: network)
        XCTAssertEqual(stopCalls, 1)
        XCTAssertNil(store.systemTailscaleInterception)
        XCTAssertEqual(store.status?.endpointMigrationPending, true)
        await store.recoverIfNeeded()
        XCTAssertEqual(client.calls, ["status", "status"])
        let next = SecureAccessPresentation.make(status: store.status, complete: false, message: nil)
        XCTAssertEqual(next.action, .repair)
        XCTAssertEqual(SecureAccessPresentation.migrationAction(for: next.action!, isSideGate: false, pending: true), "migrate-shared")
    }

    func testSemanticOrInvalidCandidateMigrationDoesNotProbeSystemVPN() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for scenario in 0..<8 {
            let client = VPNFixtureClient(); client.stopped = true
            switch scenario {
            case 0: client.failureKind = "semantic"; client.failureCode = "IDENTITY_MISMATCH"
            case 1: client.candidateURL = nil
            case 2: client.candidateURL = "https://example.com/mcp"
            case 3: client.candidateURL = "https://gate.example.ts.net/wrong"
            case 4: client.failureStatus = 401
            default: client.failureKind = "semantic"; client.failureStep = ["discovery", "resource", "mcp"][scenario - 5]
            }
            var commands = 0
            let network = SystemTailscaleVPN(command: { _, _ in commands += 1; return .init(code: 0, output: "") })
            let store = SharedGatewayStore(automaticallyRefresh: false, client: client, connectionCheck: { _, _, _ in
                let pending = ConnectionCheck.pending("Stopped")
                return .init(checkedAt: .now, bridge: pending, localMCP: pending, publicEndpoint: pending, publicMCP: pending, address: pending)
            }, diagnosticsLogFile: directory.appendingPathComponent("log"), systemVPN: network)
            await store.refresh()
            XCTAssertEqual(store.status?.running, false)
            XCTAssertNil(store.systemTailscaleInterception)
            XCTAssertEqual(commands, 0)
        }
    }

    func testConfirmationAndRecheckPreservePendingMigration() async throws {
        let client = VPNFixtureClient()
        let id = "653460BD-8619-4BC4-9EDD-7FB5658CF3BE"
        let evidence = SystemTailscaleVPN.Interception(hostname: "gate.example.ts.net", service: .init(id: id, provider: SystemTailscaleVPN.provider, connected: true))
        var checks = 0
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedGatewayStore(automaticallyRefresh: false, client: client, connectionCheck: { _, _, _ in
            checks += 1
            var diagnostics = ConnectionDiagnostics(checkedAt: .now, bridge: .success("ok"), localMCP: .success("ok"),
                publicEndpoint: checks == 1 ? .failure("DNS", error: URLError(.dnsLookupFailed)) : .success("ok"),
                publicMCP: .success("ok"), address: .success("ok"))
            diagnostics.systemTailscaleInterception = checks == 1 ? evidence : nil
            return diagnostics
        }, diagnosticsLogFile: directory.appendingPathComponent("diagnostics.log"))
        await store.refresh()
        XCTAssertFalse(store.canRepairDNSCache)
        var commands = 0, lists = 0
        let network = SystemTailscaleVPN(command: { _, args in
            commands += 1
            if args.contains("list") {
                lists += 1
                return .init(code: 0, output: "* (\(lists == 1 ? "Connected" : "Disconnected")) \(id) VPN (io.tailscale.ipn.macsys) \"Tailscale\"")
            }
            XCTAssertEqual(args, ["--nc", "stop", id])
            return .init(code: 0, output: "")
        }, settle: {})
        await store.disconnectSystemTailscale(confirmed: false, network: network)
        XCTAssertEqual(commands, 0)
        await store.disconnectSystemTailscale(confirmed: true, network: network)
        XCTAssertEqual(checks, 2)
        XCTAssertNil(store.diagnostics?.systemTailscaleInterception)
        XCTAssertTrue(store.usable)
        XCTAssertTrue(store.status?.endpointMigrationPending == true)
        XCTAssertEqual(client.calls, ["status", "status"])
        XCTAssertNil(store.message)
    }
}
