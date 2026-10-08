import XCTest
@testable import C2CManager

final class AISetupStoreTests: XCTestCase {
    @MainActor
    func testResumeConfigureAndAuthorizationWithoutPersistingSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ai-setup.json")
        let store = AISetupStore(file: file)
        XCTAssertTrue(store.begin(.claude, gateID: "main"))
        XCTAssertEqual(AISetupStore(file: file).draft?.stage, .configureClient)
        store.authorize()
        store.attach(.init(sessionID: "session", pairingCode: "SECRET-CODE", expiresAt: 0, roots: []))
        let resumed = AISetupStore(file: file)
        XCTAssertEqual(resumed.draft?.app, .claude)
        XCTAssertEqual(resumed.draft?.stage, .authorize)
        XCTAssertEqual(resumed.draft?.pairingSessionIDs, ["session"])
        XCTAssertFalse(try String(contentsOf: file).contains("SECRET-CODE"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(resumed.clear())
        XCTAssertNil(AISetupStore(file: file).draft)
    }

    @MainActor
    func testExactPairingCorrelationIgnoresOldClientAndBackgroundRefresh() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AISetupStore(file: directory.appendingPathComponent("setup.json"))
        XCTAssertTrue(store.begin(.chatGPT, gateID: "main"))
        store.attach(.init(sessionID: "new", pairingCode: "ephemeral", expiresAt: 0, roots: []))
        var client = GatewayAIConnection(pairingSessionID: "new", authorizationSessionID: "old", clientID: "client", name: "ChatGPT",
            authorizationState: "authorized", authorizationExpiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000, reason: nil)
        store.reconcile(gateID: "main", connections: [client], pairingActive: false)
        XCTAssertEqual(store.draft?.stage, .authorize)
        client.authorizationSessionID = "new"
        store.reconcile(gateID: "main", connections: [client], pairingActive: false)
        XCTAssertEqual(store.draft?.stage, .completed)
        XCTAssertEqual(store.draft?.clientID, "client")
        XCTAssertTrue(store.begin(.claude, gateID: "main"))
        XCTAssertEqual(store.draft?.pairingSessionIDs, [])
        store.reconcile(gateID: "main", connections: [client], pairingActive: false)
        XCTAssertEqual(store.draft?.stage, .configureClient)
    }

    @MainActor
    func testDraftExpiryWaitsForReliableBackendAndPreservesAssociatedAuthorization() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var date = Date()
        let store = AISetupStore(file: directory.appendingPathComponent("setup.json"), now: { date })
        XCTAssertTrue(store.begin(.other, gateID: "main"))
        date = date.addingTimeInterval(AISetupStore.lifetime + 1)
        store.reconcile(gateID: "main", connections: nil, pairingActive: nil)
        XCTAssertNotNil(store.draft)
        store.reconcile(gateID: "main", connections: [], pairingActive: true)
        XCTAssertNotNil(store.draft)
        store.reconcile(gateID: "main", connections: [], pairingActive: false)
        XCTAssertNil(store.draft)
        XCTAssertTrue(store.begin(.other, gateID: "main"))
        store.attach(.init(sessionID: "s", pairingCode: "code", expiresAt: 0, roots: []))
        let client = GatewayAIConnection(pairingSessionID: "s", authorizationSessionID: "s", clientID: "c", name: "Unknown Client",
            authorizationState: "authorized", authorizationExpiresAt: date.addingTimeInterval(3600).timeIntervalSince1970 * 1000, reason: nil)
        date = date.addingTimeInterval(AISetupStore.lifetime + 1)
        store.reconcile(gateID: "main", connections: [client], pairingActive: false)
        XCTAssertEqual(store.draft?.stage, .completed)
    }

    @MainActor
    func testGateIdentityCannotResumeAnotherGateAndRevocationClearsCompletion() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AISetupStore(file: directory.appendingPathComponent("setup.json"))
        XCTAssertTrue(store.begin(.claude, gateID: "main"))
        XCTAssertFalse(store.begin(.chatGPT, gateID: "main"))
        store.reconcile(gateID: "side", connections: [], pairingActive: false)
        XCTAssertNil(store.draft)
        XCTAssertTrue(store.begin(.claude, gateID: "main"))
        store.attach(.init(sessionID: "s", pairingCode: "code", expiresAt: 0, roots: []))
        let client = GatewayAIConnection(pairingSessionID: "s", authorizationSessionID: "s", clientID: "c", name: "Claude",
            authorizationState: "authorized", authorizationExpiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000, reason: nil)
        store.reconcile(gateID: "main", connections: [client], pairingActive: false)
        XCTAssertEqual(store.draft?.stage, .completed)
        store.reconcile(gateID: "main", connections: [], pairingActive: false)
        XCTAssertNil(store.draft)
    }
}
