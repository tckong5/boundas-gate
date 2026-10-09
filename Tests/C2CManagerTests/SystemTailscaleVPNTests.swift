import XCTest
@testable import C2CManager

final class SystemTailscaleVPNTests: XCTestCase {
    private let id = "653460BD-8619-4BC4-9EDD-7FB5658CF3BE"
    private let other = "492BC363-F196-4522-B647-B57827FCF391"
    private let host = "boundas-gate-012345abc678.example.ts.net"
    private func list(_ state: String = "Connected", provider: String = SystemTailscaleVPN.provider) -> String {
        "* (\(state)) \(id) VPN (\(provider)) \"Renamed VPN\"\n* (Connected) \(other) VPN (com.surfshark.vpnclient.macos.direct) \"Surfshark\""
    }
    private func evidence() -> SystemTailscaleVPN.Interception {
        .init(hostname: host, service: .init(id: id, provider: SystemTailscaleVPN.provider, connected: true))
    }
    func testConnectedPrivateAddressTransportFailure() {
        XCTAssertEqual(SystemTailscaleVPN.classify(hostname: host, transportFailure: true,
            services: SystemTailscaleVPN.services(in: list()), addresses: ["100.71.254.85"]), evidence())
    }
    func testDisconnectedAndUnrelatedVPNDoNotClassify() {
        for services in [list("Disconnected"), list(provider: "com.nordvpn.NordVPN")] {
            XCTAssertNil(SystemTailscaleVPN.classify(hostname: host, transportFailure: true,
                services: SystemTailscaleVPN.services(in: services), addresses: ["100.71.254.85"]))
        }
    }
    func testHealthyPublicEndpointDoesNotClassify() {
        XCTAssertNil(SystemTailscaleVPN.classify(hostname: host, transportFailure: false,
            services: SystemTailscaleVPN.services(in: list()), addresses: ["100.71.254.85"]))
    }
    func testOrdinaryDNSFailureAndOtherHostnameDoNotClassify() {
        for (hostname, addresses) in [(host, []), (host, ["103.84.155.153"]), ("example.com", ["100.71.254.85"])] {
            XCTAssertNil(SystemTailscaleVPN.classify(hostname: hostname, transportFailure: true,
                services: SystemTailscaleVPN.services(in: list()), addresses: addresses))
        }
    }
    func testCGNATBoundaries() {
        for address in ["100.64.0.0", "100.127.255.255"] { XCTAssertTrue(SystemTailscaleVPN.isTailnetAddress(address)) }
        for address in ["100.63.255.255", "100.128.0.0", "100.71.254.999", "100.71.254", "10.1.1.1"] { XCTAssertFalse(SystemTailscaleVPN.isTailnetAddress(address)) }
    }
    func testConfirmationRequiredBeforeAnyCommand() async {
        var calls = 0
        let network = SystemTailscaleVPN(command: { _, _ in calls += 1; return .init(code: 0, output: "") }, settle: {})
        do { try await network.disconnect(evidence(), confirmed: false, recheck: { XCTFail("No recheck") }); XCTFail("Expected confirmation") }
        catch { XCTAssertEqual(error as? SystemTailscaleVPN.RecoveryError, .confirmationRequired) }
        XCTAssertEqual(calls, 0)
    }
    func testOnlyVerifiedUUIDStoppedAndSuccessfulDisconnectRechecks() async throws {
        var calls: [[String]] = [], lists = 0, rechecks = 0
        let network = SystemTailscaleVPN(command: { executable, args in
            XCTAssertEqual(executable, "/usr/sbin/scutil")
            calls.append(args)
            if args == ["--nc", "list"] {
                lists += 1
                return .init(code: 0, output: self.list(lists == 1 ? "Connected" : "Disconnected"))
            }
            XCTAssertEqual(args, ["--nc", "stop", self.id])
            return .init(code: 0, output: "")
        }, settle: {})
        try await network.disconnect(evidence(), confirmed: true) { rechecks += 1 }
        XCTAssertEqual(calls, [["--nc", "list"], ["--nc", "stop", id], ["--nc", "list"]])
        XCTAssertEqual(rechecks, 1)
        XCTAssertFalse(calls.contains(where: { $0.contains(other) }))
    }
    func testProviderChangedRejectsWithoutStop() async {
        var calls = 0
        let network = SystemTailscaleVPN(command: { _, args in
            calls += 1; XCTAssertEqual(args, ["--nc", "list"])
            return .init(code: 0, output: self.list(provider: "com.nordvpn.NordVPN"))
        }, settle: {})
        do { try await network.disconnect(evidence(), confirmed: true, recheck: {}); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? SystemTailscaleVPN.RecoveryError, .serviceChanged) }
        XCTAssertEqual(calls, 1)
    }
    func testFailedDisconnectHasNoFallbackOrRecheck() async {
        var calls = 0
        let network = SystemTailscaleVPN(command: { _, args in
            calls += 1
            return .init(code: args.contains("stop") ? 1 : 0, output: self.list())
        }, settle: {})
        do { try await network.disconnect(evidence(), confirmed: true, recheck: { XCTFail("No recheck") }); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? SystemTailscaleVPN.RecoveryError, .commandFailed) }
        XCTAssertEqual(calls, 2)
    }
    func testStillConnectedFailsWithoutFallback() async {
        let network = SystemTailscaleVPN(command: { _, _ in .init(code: 0, output: self.list()) }, settle: {})
        do { try await network.disconnect(evidence(), confirmed: true, recheck: { XCTFail("No recheck") }); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? SystemTailscaleVPN.RecoveryError, .stillConnected) }
    }
    func testDetectionUsesSystemLookupAndNoAppBundle() async {
        var calls: [[String]] = []
        let network = SystemTailscaleVPN(command: { _, args in
            calls.append(args)
            return .init(code: 0, output: args.contains("list") ? self.list() : "name: \(self.host)\nip_address: 100.71.254.85\n")
        }, settle: {})
        let result = await network.detect(hostname: host, transportFailure: true)
        XCTAssertEqual(result, evidence())
        XCTAssertEqual(calls.last, ["-q", "host", "-a", "name", host])
    }
    func testHTTPFailureNotTransportFailure() {
        XCTAssertFalse(ConnectionCheck.failure("HTTP 503").isTransportFailure)
        XCTAssertTrue(ConnectionCheck.failure("Refused", error: URLError(.cannotConnectToHost)).isTransportFailure)
    }
}
