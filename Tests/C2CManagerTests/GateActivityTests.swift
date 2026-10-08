import XCTest
import SwiftUI
@testable import C2CManager

final class GateActivityTests: XCTestCase {
    func testFolderConnectorStartsAtGateAndMatchesContinuousTrafficCurve() {
        let gate = GateMapGeometry.gatePoint(width: 600)
        var connector = Path()
        GateMapGeometry.appendFolder(to: &connector, gate: gate, destinationX: 362)
        var elements: [Path.Element] = []
        connector.forEach { elements.append($0) }
        XCTAssertEqual(elements.count, 2)
        guard case .move(let start) = elements.first else { return XCTFail("Missing connector origin") }
        XCTAssertEqual(start, gate)
        var routeElements: [Path.Element] = []
        GateMapGeometry.route(sourceX: 238, gate: gate, destinationX: 362).forEach { routeElements.append($0) }
        XCTAssertEqual(routeElements.count, 3, "Request/response must remain a single continuous path")
        guard case .curve(let end, let c1, let c2) = elements.last,
              case .curve(let routeEnd, let routeC1, let routeC2) = routeElements.last else {
            return XCTFail("Missing Folder curve")
        }
        XCTAssertEqual(end, routeEnd); XCTAssertEqual(c1, routeC1); XCTAssertEqual(c2, routeC2)
    }
    private func client(_ id: String, state: String = "authorized") -> GatewayAIConnection {
        .init(clientID: id, name: id, authorizationState: state,
              authorizationExpiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000, reason: nil)
    }
    private func request(_ id: String, folder: String? = "folder", client: String = "Claude") -> GateActivityRequest {
        .init(requestID: id, gateID: "main", clientID: client, workspaceID: folder, tool: "Read", startedAt: 1000)
    }
    private func event(_ id: String, sequence: Int, finish: Bool = false, success: Bool = true) -> GateActivityEvent {
        .init(requestID: id, gateID: "main", clientID: "Claude", workspaceID: "folder", tool: "Read", startedAt: 1000,
              timestamp: finish ? 1100 : 1000, type: finish ? "requestFinished" : "requestStarted", sequence: sequence,
              success: finish ? success : nil, duration: finish ? 100 : nil)
    }
    private func page(_ cursor: Int, reset: Bool = false, events: [GateActivityEvent] = [], active: [GateActivityRequest] = [], stream: String = "stream") -> GateActivityPage {
        .init(version: 1, gateID: "main", streamID: stream, cursor: cursor, reset: reset, events: events,
              activeRequests: active, folders: [])
    }

    func testTopologyDerivesEffectiveSharingAndRecordRenameWithoutSideLeakage() {
        var record = WorkspaceRecord(name: "First", path: "/tmp", c2cID: "folder")
        record.sideGateAdded = true
        let root = GatewayRoot(id: "folder", sourceID: record.id.uuidString, name: "old name", path: "/tmp",
                               enabled: true, epoch: "e", codeRequired: true, codeEpoch: nil)
        let make = { (roots: [GatewayRoot], record: WorkspaceRecord) in
            GateMapTopology.make(roots: roots, records: [record], connections: [], availability: ["folder": true])
        }
        XCTAssertTrue(make([], record).folders.isEmpty)
        XCTAssertEqual(make([root], record).folders.first?.name, "First")
        XCTAssertTrue(make([root], record).folders.first?.protected == true)
        record.name = "Renamed"
        XCTAssertEqual(make([root], record).folders.first?.name, "Renamed")
        XCTAssertTrue(make([], record).folders.isEmpty)
        record.mainGateAdded = false
        XCTAssertTrue(make([root], record).folders.isEmpty)
        XCTAssertTrue(GateMapTopology.make(roots: [root], records: [], connections: [], availability: [:]).folders.isEmpty)
    }

    func testAuthorizationTopologyIsNotLiveSessionAndRevokedClientsDisappear() {
        let graph = GateMapTopology.make(roots: [], records: [], connections: [client("Claude"), client("ChatGPT", state: "invalid"),
                client("Removed", state: "revoked"), client("Draft", state: "unknown")], availability: [:])
        XCTAssertEqual(graph.apps.map(\.id), ["Claude", "ChatGPT"])
        XCTAssertTrue(graph.apps[0].authorized); XCTAssertFalse(graph.apps[1].authorized)
        XCTAssertTrue(graph.folders.isEmpty)
        XCTAssertTrue(graph.allowsRoute(request("a", folder: nil)))
        XCTAssertFalse(graph.allowsRoute(request("a", folder: nil, client: "ChatGPT")))
        XCTAssertTrue(GateMapTopology.make(roots: [], records: [], connections: [], availability: [:]).apps.isEmpty)
    }

    @MainActor func testConcurrentStartFinishAndLongRequestDoNotOverwriteOrInventReturnTraffic() async throws {
        let model = GateActivityModel(pulseDuration: 0.03)
        model.receive(page(0, reset: true), gateID: "main")
        model.receive(page(2, events: [event("a", sequence: 1), event("b", sequence: 2)], active: [request("a"), request("b")]), gateID: "main")
        XCTAssertEqual(model.routes.count, 2)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.routes["a"]?.phase, .waiting)
        model.receive(page(3, events: [event("b", sequence: 3, finish: true, success: false)], active: [request("a")]), gateID: "main")
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(model.routes["b"]?.phase, .response)
        XCTAssertEqual(model.routes["b"]?.success, false)
        XCTAssertEqual(model.routes["a"]?.phase, .waiting)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertNil(model.routes["b"]); XCTAssertNotNil(model.routes["a"])
        model.stop(); XCTAssertTrue(model.routes.isEmpty)
    }

    @MainActor func testFastRequestFinishesInSameBatchAndResumeDoesNotReplay() async throws {
        let model = GateActivityModel(pulseDuration: 0.02)
        model.receive(page(0, reset: true), gateID: "main")
        model.receive(page(2, events: [event("fast", sequence: 1), event("fast", sequence: 2, finish: true)]), gateID: "main")
        XCTAssertEqual(model.routes["fast"]?.phase, .request)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.routes["fast"]?.phase, .response)
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertTrue(model.routes.isEmpty)
        model.receive(page(50, reset: true, events: [event("old", sequence: 49)], active: [request("long")], stream: "new"), gateID: "main")
        XCTAssertEqual(model.routes.count, 1); XCTAssertEqual(model.routes["long"]?.phase, .waiting)
        XCTAssertNil(model.routes["old"])
    }

    @MainActor func testReduceMotionDisablesTravellingButRetainsActiveHighlights() {
        let route = GateActivityModel.Route(request: request("a"), phase: .request)
        XCTAssertTrue(GateActivityModel.travels(route, reduceMotion: false))
        XCTAssertFalse(GateActivityModel.travels(route, reduceMotion: true))
        XCTAssertFalse(GateActivityModel.travels(.init(request: request("a"), phase: .waiting), reduceMotion: false))
    }

    @MainActor func testHiddenWindowStopsPollingAndIdleHasNoRoutes() async throws {
        let client = CountingActivityClient()
        let model = GateActivityModel(client: client, cadence: 0.03)
        model.setVisible(true, gateID: "main")
        try await Task.sleep(for: .milliseconds(100))
        let count = await client.countValue()
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(model.routes.isEmpty)
        model.setVisible(false, gateID: "main")
        try await Task.sleep(for: .milliseconds(40))
        let stopped = await client.countValue()
        try await Task.sleep(for: .milliseconds(100))
        let final = await client.countValue()
        XCTAssertEqual(final, stopped)
        XCTAssertNil(model.cursor)
    }

    @MainActor func testOnboardingCompletionIsPersistentGateScopedAndSurvivesCancelAndRevoke() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("setup.json")
        let store = AISetupStore(file: file)
        store.begin(.claude, gateID: "main"); store.authorize(); store.clear()
        XCTAssertTrue(store.completedGateIDs.isEmpty)
        store.observeAuthorization(gateID: "main", connections: [client("Claude", state: "invalid")])
        XCTAssertTrue(store.completedGateIDs.isEmpty)
        store.observeAuthorization(gateID: "main", connections: [client("Claude")])
        store.observeAuthorization(gateID: "main", connections: [])
        store.begin(.other, gateID: "main"); store.clear()
        let resumed = AISetupStore(file: file)
        XCTAssertTrue(resumed.completedGateIDs.contains("main"))
        XCTAssertFalse(resumed.completedGateIDs.contains("side"))
        XCTAssertNil(resumed.draft)
    }

    func testPrivateRuntimeRejectsAnotherGateMalformedCredentialsAndPort() {
        let valid = GateActivityClient.Runtime(service: "boundas-gateway", workspaceId: "main", port: 1234,
                     instanceID: String(repeating: "a", count: 64), adminToken: "bg_admin_" + String(repeating: "b", count: 64))
        XCTAssertTrue(valid.matches(gateID: "main")); XCTAssertFalse(valid.matches(gateID: "side"))
        XCTAssertFalse(GateActivityClient.Runtime(service: "boundas-gateway", workspaceId: "main", port: 99999,
                       instanceID: valid.instanceID, adminToken: "secret").matches(gateID: "main"))
    }
}

private actor CountingActivityClient: GateActivityFetching {
    private var count = 0
    func countValue() -> Int { count }
    func fetch(gateID: String, since: Int?) async throws -> GateActivityPage {
        count += 1
        return .init(version: 1, gateID: gateID, streamID: "s", cursor: 0, reset: since == nil, events: [], activeRequests: [], folders: [])
    }
}
