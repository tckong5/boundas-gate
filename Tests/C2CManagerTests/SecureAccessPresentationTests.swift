import XCTest
@testable import C2CManager

final class SecureAccessPresentationTests: XCTestCase {
    func testSharedSideUsesExistingAccountWithoutRequestingAnotherLogin() {
        var value = status("ready")
        value.sharedTunnel = true; value.transport = "shared"; value.localOnly = true
        let next = SecureAccessPresentation.make(status: value, complete: false, message: nil, isSideGate: true)
        XCTAssertEqual(next.action, .setUp)
        XCTAssertTrue(next.description.contains("existing Tailscale"))
        value.transportSetup = .init(state: "login", message: "Account signed out", loginURL: nil, approvalURL: nil, hostname: nil, userspace: true)
        let signedOut = SecureAccessPresentation.make(status: value, complete: false, message: nil, isSideGate: true)
        XCTAssertEqual(signedOut.button, "Sign In")
        XCTAssertFalse(signedOut.description.contains("authorize secure access for this Side Gate"))
    }
    private func status(_ state: String, external: Bool = false, login: String? = nil, approval: String? = nil) -> GatewayStatus {
        var value = GatewayStatus(running: false, state: "stopped", reason: nil, gatewayID: "main", port: nil,
            pid: nil, publicUrl: nil, tunnel: nil, tokenCount: 0, pairingActive: false, roots: [],
            configuredMCPURL: nil, accessCodeVersion: nil, folderAccess: nil)
        value.transport = external ? "external" : "embedded"
        value.transportSetup = .init(state: state, message: "Technical detail", loginURL: login,
                                    approvalURL: approval, hostname: nil, userspace: nil)
        return value
    }
    func testProviderReadinessAloneDoesNotClaimExternalReachability() {
        let result = SecureAccessPresentation.make(status: status("ready"), complete: false, message: nil)
        XCTAssertEqual(result.action, .repair)
        XCTAssertNotEqual(result.description, "Tailscale · Connected")
        let healthy = SecureAccessPresentation.make(status: status("ready"), complete: true, message: nil)
        XCTAssertNil(healthy.action)
        XCTAssertEqual(healthy.description, "Tailscale · Connected")
    }

    func testLocalDNSFailureOffersExplicitCacheRepairInsteadOfTunnelRestart() {
        var value = status("ready")
        value = GatewayStatus(running: true, state: "running", reason: nil, gatewayID: value.gatewayID,
            port: 55803, pid: 1, publicUrl: "https://gate.example.ts.net/c2c/abcdef123456",
            tunnel: .init(running: true, url: "https://gate.example.ts.net/c2c/abcdef123456"),
            tokenCount: 0, pairingActive: false, roots: [], configuredMCPURL: nil,
            accessCodeVersion: nil, folderAccess: nil)
        let diagnostics = ConnectionDiagnostics(checkedAt: .now, bridge: .success("ok"), localMCP: .success("ok"),
            publicEndpoint: .failure("DNS failed", error: URLError(.dnsLookupFailed)),
            publicMCP: .pending("not checked"), address: .success("matches"))
        let result = SecureAccessPresentation.make(status: value, complete: false, message: nil, diagnostics: diagnostics)
        XCTAssertEqual(result.action, .repairDNS)
        XCTAssertEqual(result.button, "Repair")
        XCTAssertTrue(result.description.contains("cache"))
        XCTAssertNotEqual(result.description, "Tailscale · Connected")
    }
    func testInlineNextActionsComeFromPreflight() {
        var firstRun = status("unconfigured")
        firstRun = GatewayStatus(running: false, state: "stopped", reason: nil, gatewayID: nil, port: nil,
            pid: nil, publicUrl: nil, tunnel: nil, tokenCount: 0, pairingActive: false, roots: [],
            configuredMCPURL: nil, accessCodeVersion: nil, folderAccess: nil)
        XCTAssertEqual(SecureAccessPresentation.make(status: firstRun, complete: false, message: nil).action, .setUp)
        XCTAssertEqual(SecureAccessPresentation.make(status: status("unconfigured"), complete: false, message: nil).action, .setUp)
        XCTAssertEqual(SecureAccessPresentation.make(status: status("login", external: true), complete: false, message: nil).action, .signIn)
        let approval = SecureAccessPresentation.make(status: status("blocked", approval: "https://login.tailscale.com/admin/machines"), complete: false, message: nil)
        XCTAssertEqual(approval.action, .approve)
        XCTAssertEqual(approval.button, "Continue Authorization")
        let untrusted = SecureAccessPresentation.make(status: status("blocked", approval: "https://evil.test/"), complete: false, message: nil)
        XCTAssertEqual(untrusted.action, .repair)
        XCTAssertNil(untrusted.approvalURL)
        XCTAssertEqual(SecureAccessPresentation.make(status: status("starting"), complete: false, message: nil).action, .recheck)
    }

    func testSignOutRequiresConfirmedSignedInProviderState() {
        for external in [false, true] {
            for state in ["login", "starting", "unconfigured", "missing", "blocked"] {
                XCTAssertFalse(SecureAccessPresentation.make(status: status(state, external: external),
                    complete: false, message: nil).canSignOut)
            }
            // Public reachability can fail even though the account is signed in.
            XCTAssertTrue(SecureAccessPresentation.make(status: status("ready", external: external),
                complete: false, message: nil).canSignOut)
            XCTAssertTrue(SecureAccessPresentation.make(status: status("ready", external: external),
                complete: true, message: nil).canSignOut)
        }
        XCTAssertFalse(SecureAccessPresentation.make(status: nil, complete: false, message: nil).canSignOut)
    }

    func testSignInPromptNeverOffersSignOutEvenWithStaleReadyState() {
        let value = status("ready", login: "https://login.tailscale.com/login")
        let result = SecureAccessPresentation.make(status: value, complete: false, message: nil)
        XCTAssertEqual(result.action, .signIn)
        XCTAssertFalse(result.canSignOut)
    }
    func testSignedInLocalOnlyGateStillRequiresExplicitSecureAccessSetup() {
        var value = status("ready")
        value.localOnly = true
        let result = SecureAccessPresentation.make(status: value, complete: false, message: nil)
        XCTAssertEqual(result.action, .setUp)
        XCTAssertNotEqual(result.description, "Tailscale · Connected")
    }

    func testLegacyCloudflareDoesNotOfferTailscaleAccountActions() {
        var value = status("ready")
        value.transport = "cloudflare"
        value.localOnly = true
        let pending = SecureAccessPresentation.make(status: value, complete: false, message: nil)
        XCTAssertEqual(pending.action, .setUp)
        XCTAssertFalse(pending.canSignOut)
        let complete = SecureAccessPresentation.make(status: value, complete: true, message: nil)
        XCTAssertEqual(complete.description, "Secure access is available.")
        XCTAssertFalse(complete.canSignOut)
    }

}
