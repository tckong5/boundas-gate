import XCTest
@testable import C2CManager

final class SharedGatewayConnectionTests: XCTestCase {
    private func status(running: Bool?, state: String, tunnelRunning: Bool = true) -> GatewayStatus {
        .init(running: running, state: state, reason: nil, gatewayID: "abcdef123456", port: 56148,
              pid: 1, publicUrl: "https://mac.example.ts.net/c2c/abcdef123456",
              tunnel: .init(running: tunnelRunning, url: "https://mac.example.ts.net/c2c/abcdef123456"),
              tokenCount: 0, pairingActive: false, roots: [], configuredMCPURL: nil,
              accessCodeVersion: 1, folderAccess: [])
    }

    private var healthy: ConnectionDiagnostics {
        .init(checkedAt: Date(), bridge: .success("ok"), localMCP: .success("ok"),
              publicEndpoint: .success("ok"), publicMCP: .success("ok"), address: .success("ok"))
    }

    func testStoppedGatewayOffersStartDespitePreviousHealthyChecks() {
        let result = GatewayConnectionState.make(status: status(running: false, state: "stopped"),
                                                 diagnostics: healthy, checking: false)
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(result.button, "Open Main Gate")
    }

    func testUnknownStatusOffersCheckInsteadOfStartOrRepair() {
        for value in [nil, status(running: nil, state: "unknown"), status(running: true, state: "unknown")] {
            let result = GatewayConnectionState.make(status: value, diagnostics: healthy, checking: false)
            XCTAssertEqual(result, .unknown)
            XCTAssertEqual(result.button, "重新檢查")
        }
    }

    func testInitialCheckDoesNotClaimGatewayIsStopped() {
        XCTAssertEqual(GatewayConnectionState.make(status: nil, diagnostics: nil, checking: true), .checking)
    }

    func testStoppedTunnelCannotUseOldHealthyDiagnostics() {
        let result = GatewayConnectionState.make(status: status(running: true, state: "running", tunnelRunning: false),
                                                 diagnostics: healthy, checking: false)
        XCTAssertEqual(result, .needsRepair)
        XCTAssertEqual(result.button, "Repair Main Gate")
    }

    func testRunningGatewayWithoutPassedPublicChecksNeedsRepair() {
        XCTAssertEqual(GatewayConnectionState.make(status: status(running: true, state: "running"),
                                                   diagnostics: nil, checking: false), .needsRepair)
    }

    func testHealthySharedGatewayOffersURLWithoutRequiringIndependentConnections() {
        let result = GatewayConnectionState.make(status: status(running: true, state: "running"),
                                                 diagnostics: healthy, checking: false)
        XCTAssertEqual(result, .ready)
        XCTAssertEqual(result.button, "複製 URL · 開啟 ChatGPT")
    }
}
