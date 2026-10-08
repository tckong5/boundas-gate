import XCTest
@testable import C2CManager

final class GateUIContextTests: XCTestCase {
    func testMainAndSideSetupCopyAndFilesAreIndependent() {
        let folder = WorkspaceRecord(name: "Test Folder", path: "/tmp/folder", c2cID: "abcdef123456")
        let main = GateUIContext.main, side = GateUIContext.side(folder)
        XCTAssertEqual(main.appName, "Boundas Gate")
        XCTAssertEqual(main.appDescription, "Access folders shared through Boundas Gate.")
        XCTAssertEqual(side.appName, "Boundas Gate · Test Folder")
        XCTAssertEqual(side.appDescription, "Access only Test Folder through its Side Gate.")
        XCTAssertEqual(side.localTitle, "Side Gate")
        XCTAssertEqual(side.localInstruction, "Start the local MCP host for this Folder.")
        let directory = URL(fileURLWithPath: "/tmp/profile")
        XCTAssertNotEqual(main.setupFile(in: directory), side.setupFile(in: directory))
        var renamed = folder; renamed.name = "Renamed"
        XCTAssertEqual(side.setupFile(in: directory), GateUIContext.side(renamed).setupFile(in: directory))
    }

    @MainActor
    func testSideSetupResumeDoesNotReplaceMainOrAnotherSideDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = WorkspaceRecord(name: "A", path: "/tmp/a", c2cID: "abcdef123456")
        let b = WorkspaceRecord(name: "B", path: "/tmp/b", c2cID: "123456abcdef")
        let main = AISetupStore(file: GateUIContext.main.setupFile(in: directory))
        let side = AISetupStore(file: GateUIContext.side(a).setupFile(in: directory))
        let other = AISetupStore(file: GateUIContext.side(b).setupFile(in: directory))
        XCTAssertTrue(main.begin(.chatGPT, gateID: "main"))
        XCTAssertTrue(side.begin(.claude, gateID: a.c2cID)); side.authorize()
        side.attach(.init(sessionID: "pair-a", pairingCode: "TEST", expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970 * 1000, roots: []))
        XCTAssertTrue(other.begin(.other, gateID: b.c2cID))
        let resumed = AISetupStore(file: GateUIContext.side(a).setupFile(in: directory))
        XCTAssertEqual(resumed.draft?.stage, .authorize)
        XCTAssertEqual(resumed.draft?.pairingSessionIDs, ["pair-a"])
        XCTAssertEqual(main.draft?.stage, .configureClient)
        XCTAssertEqual(other.draft?.gateID, b.c2cID)
    }

    func testLocalSideHostMakesSecureAccessActiveAndHealthySideCanCollapse() throws {
        var status = try JSONDecoder().decode(GatewayStatus.self, from: Data(#"{"ok":true,"gatewayID":"abcdef123456","running":true,"state":"healthy","roots":[],"localOnly":true,"tokenCount":0,"aiConnections":[],"tunnel":{"running":false}}"#.utf8))
        let local = ConnectionDiagnostics(checkedAt: .now, bridge: .success("ok"), localMCP: .success("ok"),
            publicEndpoint: .pending("not open"), publicMCP: .pending("not open"), address: .pending("not open"))
        var journey = GateConnectionJourney.make(status: status, diagnostics: local, confirmed: true, busy: false, usable: false)
        XCTAssertEqual(journey.nodes[0], .completed)
        XCTAssertEqual(journey.activeStage, .tunnel)
        XCTAssertEqual(journey.nodes[1], .waiting)
        // Reconstruct runtime evidence for a reachable Side endpoint.
        status = try JSONDecoder().decode(GatewayStatus.self, from: Data(#"{"ok":true,"gatewayID":"abcdef123456","running":true,"state":"healthy","roots":[],"localOnly":false,"transport":"embedded","transportSetup":{"state":"ready","message":"ready"},"tunnel":{"running":true},"aiConnections":[{"clientID":"side-ai","name":"Claude","authorizationState":"authorized","authorizationExpiresAt":4102444800000}]}"#.utf8))
        let healthy = ConnectionDiagnostics(checkedAt: .now, bridge: .success("ok"), localMCP: .success("ok"),
            publicEndpoint: .success("ok"), publicMCP: .success("ok"), address: .success("ok"))
        journey = GateConnectionJourney.make(status: status, diagnostics: healthy, confirmed: true, busy: false, usable: true)
        XCTAssertTrue(journey.isOpen); XCTAssertTrue(journey.isReady); XCTAssertFalse(journey.hasAIWarning)
    }
}
