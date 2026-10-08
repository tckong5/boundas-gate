import XCTest
@testable import C2CManager

final class GateConnectionJourneyTests: XCTestCase {
    private func connection(_ id: String, _ state: String) -> GatewayAIConnection {
        .init(clientID: id, name: id, authorizationState: state,
              authorizationExpiresAt: state == "authorized" ? Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000 : nil,
              reason: nil)
    }

    private func status(_ connections: [GatewayAIConnection]?) -> GatewayStatus {
        var value = GatewayStatus(running: true, state: "healthy", reason: nil, gatewayID: "abcdef123456", port: 56148,
            pid: 1, publicUrl: "https://mac.example.ts.net/c2c/abcdef123456",
            tunnel: .init(running: true, url: "https://mac.example.ts.net/c2c/abcdef123456"),
            tokenCount: 1, pairingActive: false,
            roots: [.init(id: "123456abcdef", sourceID: "folder", name: "Folder", path: "/tmp/folder", enabled: true,
                          epoch: "epoch", codeRequired: false, codeEpoch: nil)],
            configuredMCPURL: nil, accessCodeVersion: 1, folderAccess: [])
        value.aiConnections = connections
        return value
    }

    private var healthy: ConnectionDiagnostics {
        .init(checkedAt: Date(), bridge: .success("ok"), localMCP: .success("ok"),
              publicEndpoint: .success("ok"), publicMCP: .success("ok"), address: .success("ok"))
    }

    func testOneInvalidClientDoesNotCloseGateWithAnotherValidAuthorization() {
        let result = GateConnectionJourney.make(status: status([connection("ChatGPT", "authorized"), connection("Claude", "invalid")]),
            diagnostics: healthy, confirmed: true, busy: false, usable: true)
        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.attentionCount, 1)
        XCTAssertEqual(result.nodes[2], .attention)
        XCTAssertEqual(result.nodes[3], .current)
    }

    func testAllInvalidOrUnknownAuthorizationsBlockReady() {
        for clients in [[connection("A", "invalid")], [connection("A", "unknown")], [], nil] as [[GatewayAIConnection]?] {
            let result = GateConnectionJourney.make(status: status(clients), diagnostics: healthy,
                confirmed: true, busy: false, usable: true)
            XCTAssertFalse(result.isReady)
            XCTAssertTrue(result.isOpen)
            XCTAssertEqual(result.nodes[3], .pending)
        }
    }

    func testZeroFoldersAndZeroMCPConnectionsIsOpenButOnboardingIsIncomplete() {
        var value = status([])
        value = GatewayStatus(running: value.running, state: value.state, reason: nil, gatewayID: value.gatewayID,
            port: value.port, pid: value.pid, publicUrl: value.publicUrl, tunnel: value.tunnel, tokenCount: 0,
            pairingActive: false, roots: [], configuredMCPURL: nil, accessCodeVersion: 1, folderAccess: [])
        value.aiConnections = []
        var result = GateConnectionJourney.make(status: value, diagnostics: healthy, confirmed: true, busy: false, usable: true)
        XCTAssertTrue(result.isOpen); XCTAssertFalse(result.isReady)
        value.aiConnections = [connection("Claude", "authorized")]
        result = GateConnectionJourney.make(status: value, diagnostics: healthy, confirmed: true, busy: false, usable: true)
        XCTAssertTrue(result.isOpen); XCTAssertTrue(result.isReady)
    }

    func testUnfinishedRegistrationDoesNotWarnWhenAnotherClientIsAuthorized() {
        let result = GateConnectionJourney.make(status: status([connection("Claude old", "unknown"), connection("Claude", "authorized")]),
            diagnostics: healthy, confirmed: true, busy: false, usable: true)
        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.attentionCount, 0)
        XCTAssertEqual(result.nodes[2], .completed)
        XCTAssertEqual(result.activeStage, .ready)
    }

    func testValidAuthorizationCompletesWithoutManualAddressConfirmation() {
        let value = status([connection("ChatGPT", "authorized")])
        XCTAssertFalse(value.addressConfirmed)
        let result = GateConnectionJourney.make(status: value, diagnostics: healthy, confirmed: true, busy: false, usable: true)
        XCTAssertTrue(result.isReady)
        XCTAssertFalse(result.hasAIWarning)
    }

    func testPublicFailureBlocksReadyEvenWithValidAuthorization() {
        let checks = ConnectionDiagnostics(checkedAt: Date(), bridge: .success("ok"), localMCP: .success("ok"),
            publicEndpoint: .failure("unreachable"), publicMCP: .pending("unchecked"), address: .success("ok"))
        let result = GateConnectionJourney.make(status: status([connection("A", "authorized")]),
            diagnostics: checks, confirmed: true, busy: false, usable: false)
        XCTAssertFalse(result.isReady)
        XCTAssertEqual(result.activeStage, .tunnel)
        XCTAssertEqual(result.nodes[3], .pending)
    }
}
