import XCTest
@testable import C2CManager

final class GatewayReconnectPolicyTests: XCTestCase {
    private func status(running: Bool? = true, state: String = "running", desired: Bool = true,
                        enabled: Bool = true) -> GatewayStatus {
        let root = GatewayRoot(id: "abcdef123456", sourceID: "source", name: "Folder", path: "/tmp/folder",
                               enabled: true, epoch: "epoch", codeRequired: nil, codeEpoch: nil)
        var result = GatewayStatus(running: running, state: state, reason: nil, gatewayID: "abcdef123456", port: 56148,
                                   pid: 1, publicUrl: "https://mac.example.ts.net/c2c/abcdef123456",
                                   tunnel: .init(running: false, url: "https://mac.example.ts.net/c2c/abcdef123456"),
                                   tokenCount: 2, pairingActive: false, roots: [root], configuredMCPURL: nil,
                                   accessCodeVersion: 1, folderAccess: [])
        result.desiredRunning = desired
        result.reconnectEnabled = enabled
        result.stableMCPURL = "https://mac.example.ts.net/c2c/abcdef123456/mcp"
        return result
    }

    func testDisconnectedTunnelAndCrashedGatewayCanRecover() {
        for value in [status(), status(running: false, state: "stopped")] {
            var policy = GatewayReconnectPolicy()
            XCTAssertTrue(policy.shouldAttempt(status: value, usable: false, confirmed: true, busy: false))
        }
    }

    func testZeroFoldersDoesNotBlockReconnect() {
        var value = GatewayStatus(running: false, state: "stopped", reason: nil, gatewayID: "abcdef123456",
            port: nil, pid: nil, publicUrl: nil, tunnel: nil, tokenCount: 0, pairingActive: false, roots: [],
            configuredMCPURL: nil, accessCodeVersion: 1, folderAccess: [])
        value.desiredRunning = true; value.reconnectEnabled = true
        var policy = GatewayReconnectPolicy()
        XCTAssertTrue(policy.shouldAttempt(status: value, usable: false, confirmed: true, busy: false))
    }

    func testManualStopAndDisabledRecoveryNeverAutoStart() {
        for value in [status(running: false, state: "stopped", desired: false), status(enabled: false)] {
            var policy = GatewayReconnectPolicy()
            XCTAssertFalse(policy.shouldAttempt(status: value, usable: false, confirmed: true, busy: false))
        }
    }

    func testUnknownUnconfirmedAndBusyStatesNeverRepairBlindly() {
        var policy = GatewayReconnectPolicy()
        XCTAssertFalse(policy.shouldAttempt(status: status(running: nil, state: "unknown"), usable: false, confirmed: true, busy: false))
        XCTAssertFalse(policy.shouldAttempt(status: status(), usable: false, confirmed: false, busy: false))
        XCTAssertFalse(policy.shouldAttempt(status: status(), usable: false, confirmed: true, busy: true))
    }

    func testChangedAddressRequiresAttentionInsteadOfAutomaticReplacement() {
        var value = status()
        value.stableMCPURL = "https://original.example.ts.net/c2c/abcdef123456/mcp"
        var policy = GatewayReconnectPolicy()
        XCTAssertFalse(policy.shouldAttempt(status: value, usable: false, confirmed: true, busy: false))
    }

    func testRetriesBackOffAndSuccessfulRecoveryResetsThem() {
        let now = Date(timeIntervalSince1970: 1000)
        var policy = GatewayReconnectPolicy()
        XCTAssertTrue(policy.shouldAttempt(status: status(), usable: false, confirmed: true, busy: false, now: now))
        XCTAssertFalse(policy.shouldAttempt(status: status(), usable: false, confirmed: true, busy: false, now: now.addingTimeInterval(9)))
        XCTAssertTrue(policy.shouldAttempt(status: status(), usable: false, confirmed: true, busy: false, now: now.addingTimeInterval(10)))
        XCTAssertEqual(policy.nextAttemptAt, now.addingTimeInterval(30))
        XCTAssertFalse(policy.shouldAttempt(status: status(), usable: true, confirmed: true, busy: false))
        XCTAssertEqual(policy.attempts, 0)
        XCTAssertNil(policy.nextAttemptAt)
    }

    func testWakeResetsDelayWithoutOverridingManualStop() {
        var policy = GatewayReconnectPolicy()
        XCTAssertTrue(policy.shouldAttempt(status: status(), usable: false, confirmed: true, busy: false))
        policy.reset()
        XCTAssertFalse(policy.shouldAttempt(status: status(desired: false), usable: false, confirmed: true, busy: false))
    }
}
