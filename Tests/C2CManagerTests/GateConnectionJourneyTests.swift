import XCTest
@testable import C2CManager

final class GateConnectionJourneyTests: XCTestCase {
    private func connection(_ id: String, _ state: String) -> GatewayAIConnection {
        .init(clientID: id, name: id, authorizationState: state,
              authorizationExpiresAt: state == "authorized" ? Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000 : nil,
              reason: nil)
    }

    private func status(_ connections: [GatewayAIConnection]?, running: Bool = true, emptyFolders: Bool = false) -> GatewayStatus {
        var value = GatewayStatus(running: running, state: running ? "healthy" : "stopped", reason: nil, gatewayID: "abcdef123456", port: 56148,
            pid: 1, publicUrl: "https://mac.example.ts.net/c2c/abcdef123456",
            tunnel: .init(running: true, url: "https://mac.example.ts.net/c2c/abcdef123456"),
            tokenCount: 1, pairingActive: false,
            roots: emptyFolders ? [] : [.init(id: "123456abcdef", sourceID: "folder", name: "Folder", path: "/tmp/folder", enabled: true,
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
        XCTAssertEqual(result.nodes[3], .completed)
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

    func testFirstRunOnlyPresentsLocalActionsAndHidesCounts() {
        let value = GatewayStatus(running: false, state: "stopped", reason: nil, gatewayID: nil,
            port: nil, pid: nil, publicUrl: nil, tunnel: nil, tokenCount: 0, pairingActive: false,
            roots: [], configuredMCPURL: nil, accessCodeVersion: 1, folderAccess: [])
        let result = GateConnectionJourney.make(status: value, diagnostics: nil,
            confirmed: true, busy: false, usable: false)
        XCTAssertEqual(result.nodes, [.waiting, .pending, .pending, .pending])
        XCTAssertFalse(result.showsSummaryCounts)
        XCTAssertFalse(result.showsLocalCloseControl)
        XCTAssertEqual(result.summaryTitle(opening: false, reopening: false, closed: false), "Finish setting up your Gate")
        XCTAssertTrue(result.presentsPrimaryAction(for: .local))
        for stage in [GateConnectionJourney.Stage.tunnel, .aiConnection, .ready] {
            XCTAssertFalse(result.presentsContent(for: stage))
            XCTAssertFalse(result.presentsPrimaryAction(for: stage))
            XCTAssertFalse(result.presentsSecondaryActions(for: stage))
        }
    }

    func testTunnelCurrentRetainsSecondaryCloseWithoutEnablingLaterSteps() {
        let checks = ConnectionDiagnostics(checkedAt: Date(), bridge: .success("ok"), localMCP: .success("ok"),
            publicEndpoint: .failure("unreachable"), publicMCP: .pending("unchecked"), address: .success("ok"))
        let result = GateConnectionJourney.make(status: status([]), diagnostics: checks,
            confirmed: true, busy: false, usable: false)
        XCTAssertTrue(result.showsLocalCloseControl)
        XCTAssertFalse(result.presentsPrimaryAction(for: .local))
        XCTAssertTrue(result.presentsPrimaryAction(for: .tunnel))
        XCTAssertTrue(result.presentsSecondaryActions(for: .tunnel))
        XCTAssertFalse(result.presentsContent(for: .aiConnection))
        XCTAssertFalse(result.presentsContent(for: .ready))
    }

    func testAuthorizedGateSummaryAndCloseSurviveZeroFolders() {
        let value = status([connection("Claude", "authorized")], emptyFolders: true)
        let result = GateConnectionJourney.make(status: value, diagnostics: healthy,
            confirmed: true, busy: false, usable: true)
        XCTAssertTrue(result.isReady)
        XCTAssertTrue(result.showsSummaryCounts)
        XCTAssertTrue(result.showsLocalCloseControl)
        XCTAssertTrue(result.presentsSecondaryActions(for: .tunnel))
        XCTAssertEqual(result.summaryTitle(opening: false, reopening: false, closed: false), "Gate Open")
    }

    func testClosedGateShowsOpenActionAndReopeningKeepsAuthorization() {
        let clients = [connection("Claude", "authorized")]
        let value = status(clients, running: false)
        let closed = GateConnectionJourney.make(status: value, diagnostics: healthy,
            confirmed: true, busy: false, usable: false)
        XCTAssertFalse(closed.showsLocalCloseControl)
        XCTAssertTrue(closed.presentsPrimaryAction(for: .local))
        XCTAssertFalse(closed.presentsContent(for: .aiConnection))
        XCTAssertEqual(closed.summaryTitle(opening: false, reopening: false, closed: true), "Gate Closed")
        XCTAssertEqual(closed.summaryTitle(opening: true, reopening: false, closed: true), "Opening Gate…")
        XCTAssertEqual(closed.summaryTitle(opening: false, reopening: true, closed: true), "Reopening Gate…")
        let reopened = GateConnectionJourney.make(status: status(clients), diagnostics: healthy,
            confirmed: true, busy: false, usable: true)
        XCTAssertTrue(reopened.isReady)
        XCTAssertEqual(reopened.aiConnections, closed.aiConnections)
        XCTAssertEqual(value.roots.count, 1)
    }

    func testLocalOnlyAdvancesToSecureAccessWithoutDeclaringGateOpen() {
        var value = status([], emptyFolders: true)
        value.localOnly = true
        let result = GateConnectionJourney.make(status: value, diagnostics: healthy,
            confirmed: true, busy: false, usable: false)
        XCTAssertEqual(result.nodes, [.completed, .waiting, .pending, .pending])
        XCTAssertEqual(result.activeStage, .tunnel)
        XCTAssertFalse(result.isOpen)
        XCTAssertTrue(result.showsLocalCloseControl)
        XCTAssertTrue(result.presentsPrimaryAction(for: .tunnel))
        XCTAssertFalse(result.presentsContent(for: .aiConnection))
    }

    func testUserActionWaitingAndProcessingUseDistinctStates() {
        let stopped = status([], running: false)
        XCTAssertEqual(GateConnectionJourney.make(status: stopped, diagnostics: nil,
            confirmed: true, busy: false, usable: false).nodes[0], .waiting)
        XCTAssertEqual(GateConnectionJourney.make(status: stopped, diagnostics: nil,
            confirmed: true, busy: true, usable: false).nodes[0], .current)
        XCTAssertEqual(GateConnectionJourney.make(status: status([]), diagnostics: healthy,
            confirmed: true, busy: false, usable: true).nodes[2], .waiting)
        XCTAssertEqual(GateConnectionJourney.make(status: status([]), diagnostics: healthy,
            confirmed: true, busy: true, usable: true).nodes[2], .current)
    }

    func testMissingHealthEvidenceDoesNotPretendToBeProcessingWhileIdle() {
        for value in [nil, status([])] as [GatewayStatus?] {
            XCTAssertEqual(GateConnectionJourney.make(status: value, diagnostics: nil,
                confirmed: value != nil, busy: false, usable: false).nodes[0], .waiting)
            XCTAssertEqual(GateConnectionJourney.make(status: value, diagnostics: nil,
                confirmed: value != nil, busy: true, usable: false).nodes[0], .current)
        }
    }

    func testRepairCheckingUsesProcessingThenReturnsToAttentionIfFailureRemains() {
        let checks = ConnectionDiagnostics(checkedAt: Date(), bridge: .success("ok"), localMCP: .success("ok"),
            publicEndpoint: .failure("unreachable"), publicMCP: .pending("unchecked"), address: .success("ok"))
        for busy in [true, false] {
            let result = GateConnectionJourney.make(status: status([]), diagnostics: checks,
                confirmed: true, busy: busy, usable: false)
            XCTAssertEqual(result.nodes[0], .completed)
            XCTAssertEqual(result.nodes[1], busy ? .current : .attention)
            XCTAssertEqual(result.nodes[2], .pending)
            XCTAssertEqual(result.nodes[3], .pending)
        }
    }
}
