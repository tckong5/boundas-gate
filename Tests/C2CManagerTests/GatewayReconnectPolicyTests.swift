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

    func testLocalDNSFailureDoesNotRestartAnAlreadyRunningTunnel() {
        var value = status()
        value = GatewayStatus(running: true, state: "running", reason: nil, gatewayID: value.gatewayID,
            port: value.port, pid: value.pid, publicUrl: value.publicUrl,
            tunnel: .init(running: true, url: value.publicUrl), tokenCount: 0, pairingActive: false,
            roots: [], configuredMCPURL: nil, accessCodeVersion: 1, folderAccess: [])
        value.desiredRunning = true
        let dnsFailure = ConnectionDiagnostics(checkedAt: .now, bridge: .success("ok"), localMCP: .success("ok"),
            publicEndpoint: .failure("host not found", error: URLError(.cannotFindHost)),
            publicMCP: .pending("public DNS failed"), address: .success("matches"))
        var policy = GatewayReconnectPolicy()
        XCTAssertFalse(policy.shouldAttempt(status: value, usable: false, confirmed: true,
                                            busy: false, diagnostics: dnsFailure))
        XCTAssertEqual(policy.attempts, 0)
        XCTAssertNil(policy.nextAttemptAt)
        // A real route failure must still recover even when DNS also fails.
        XCTAssertTrue(policy.shouldAttempt(status: status(), usable: false, confirmed: true,
                                           busy: false, diagnostics: dnsFailure))
    }

    func testZeroFoldersDoesNotBlockReconnect() {
        var value = GatewayStatus(running: false, state: "stopped", reason: nil, gatewayID: "abcdef123456",
            port: nil, pid: nil, publicUrl: nil, tunnel: nil, tokenCount: 0, pairingActive: false, roots: [],
            configuredMCPURL: nil, accessCodeVersion: 1, folderAccess: [])
        value.desiredRunning = true; value.reconnectEnabled = true
        var policy = GatewayReconnectPolicy()
        XCTAssertTrue(policy.shouldAttempt(status: value, usable: false, confirmed: true, busy: false))
    }

    func testLocalOnlyDoesNotStartSecureAccessButCanRecoverLocalHost() {
        var value = status()
        value.localOnly = true
        var policy = GatewayReconnectPolicy()
        XCTAssertFalse(policy.shouldAttempt(status: value, usable: false, confirmed: true, busy: false))
        value = status(running: false, state: "stopped")
        value.localOnly = true
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
    func testWaitingForConsentDoesNotContinuouslyEnterReconnecting() {
        for state in ["login", "blocked", "starting", "unconfigured", "missing"] {
            var value = status()
            value.localOnly = false
            value.transportSetup = .init(state: state, message: "waiting", loginURL: nil,
                approvalURL: nil, hostname: nil, userspace: true)
            var policy = GatewayReconnectPolicy()
            XCTAssertFalse(policy.shouldAttempt(status: value, usable: false, confirmed: true, busy: false))
            XCTAssertEqual(policy.attempts, 0)
            value.transportSetup = .init(state: "ready", message: "signed in", loginURL: nil,
                approvalURL: nil, hostname: nil, userspace: true)
            XCTAssertTrue(policy.shouldAttempt(status: value, usable: false, confirmed: true, busy: false))
        }
    }

}
