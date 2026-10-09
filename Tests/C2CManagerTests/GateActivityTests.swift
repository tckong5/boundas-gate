import XCTest
import SwiftUI
@testable import C2CManager

final class GateActivityTests: XCTestCase {
    func testFolderConnectorStartsAtGateAndMatchesContinuousTrafficCurve() {
        let gate = CGPoint(x: 300, y: 185)
        var connector = Path()
        GateMapGeometry.appendFolder(to: &connector, gate: gate, destination: CGPoint(x: 362, y: 282))
        var elements: [Path.Element] = []
        connector.forEach { elements.append($0) }
        XCTAssertEqual(elements.count, 2)
        guard case .move(let start) = elements.first else { return XCTFail("Missing connector origin") }
        XCTAssertEqual(start, gate)
        var routeElements: [Path.Element] = []
        GateMapGeometry.route(source: CGPoint(x: 238, y: 104), gate: gate, destination: CGPoint(x: 362, y: 282)).forEach { routeElements.append($0) }
        XCTAssertEqual(routeElements.count, 3, "Request/response must remain a single continuous path")
        guard case .curve(let end, let c1, let c2) = elements.last,
              case .curve(let routeEnd, let routeC1, let routeC2) = routeElements.last else {
            return XCTFail("Missing Folder curve")
        }
        XCTAssertEqual(end, routeEnd); XCTAssertEqual(c1, routeC1); XCTAssertEqual(c2, routeC2)
    }
    func testResponsiveLayersFitViewportAndStayIndependent() {
        for width: CGFloat in [434, 574, 800, 1040] {
            for apps in [1, 3, 8, 12] {
                for folders in [2, 4, 8, 9, 12] {
                    let layout = GateMapLayout(width: width, appCount: apps, folderCount: folders)
                    XCTAssertEqual(layout.width, width)
                    XCTAssertEqual(layout.gate.x, width / 2)
                    for layer in [layout.apps, layout.folders] {
                        XCTAssertLessThanOrEqual(layer.rows, 2)
                        for point in layer.positions {
                            XCTAssertGreaterThanOrEqual(point.x - (layer.labelWidth + 4) / 2, 12 - 0.01)
                            XCTAssertLessThanOrEqual(point.x + (layer.labelWidth + 4) / 2, width - 12 + 0.01)
                            XCTAssertGreaterThan(point.y - 43, 0)
                            XCTAssertLessThan(point.y + 43, layout.height)
                        }
                    }
                    XCTAssertEqual(layout.apps.positions, GateMapLayout(width: width, appCount: apps, folderCount: 1).apps.positions)
                    XCTAssertEqual(layout.folders.labelWidth, GateMapLayout(width: width, appCount: 1, folderCount: folders).folders.labelWidth)
                }
            }
        }
        let sparse = GateMapLayout(width: 800, appCount: 1, folderCount: 4)
        XCTAssertEqual(sparse.height, 385)
        XCTAssertEqual(sparse.folders.rows, 1)
        XCTAssertEqual(sparse.folders.positions[1].x - sparse.folders.positions[0].x, 124)
        XCTAssertEqual(GateMapLayout(width: 900, appCount: 1, folderCount: 8).folders.rows, 1)
        XCTAssertEqual(GateMapLayout(width: 434, appCount: 1, folderCount: 8).folders.rows, 2)
        XCTAssertEqual(GateMapLayout(width: 1040, appCount: 1, folderCount: 9).folders.rows, 2)
    }

    func testOuterRowGeometryMatchesTrafficAndPreservesAILabelClearance() {
        for width: CGFloat in [434, 574, 800] {
            for count in [8, 9, 10, 12] {
                let layout = GateMapLayout(width: width, appCount: count, folderCount: count)
                for (layer, incoming) in [(layout.apps, true), (layout.folders, false)] {
                    let labels = zip(layer.positions, layer.corridors).compactMap { point, corridor -> CGRect? in
                        guard corridor == nil else { return nil }
                        return CGRect(x: point.x - layer.labelWidth / 2, y: point.y + 5, width: layer.labelWidth, height: 38)
                    }
                    for index in layer.positions.indices where layer.corridors[index] != nil {
                        var connector = Path()
                        if incoming {
                            GateMapGeometry.appendAI(to: &connector, source: layer.anchors[index], gate: layout.gate, corridor: layer.corridors[index])
                        } else {
                            GateMapGeometry.appendFolder(to: &connector, gate: layout.gate, destination: layer.anchors[index],
                                                         corridor: layer.corridors[index])
                        }
                        if incoming {
                            for sample in 1...400 {
                                let point = connector.trimmedPath(from: 0, to: CGFloat(sample) / 400).cgPath.currentPoint
                                XCTAssertFalse(labels.contains { $0.contains(point) }, "Curve crosses an AI label at \(width)/\(count): \(point)")
                            }
                        }
                        let route = GateMapGeometry.route(source: layout.apps.anchors[0], gate: layout.gate,
                            destination: layout.folders.anchors[index], incomingCorridor: layout.apps.corridors[0],
                            outgoingCorridor: layout.folders.corridors[index])
                        var moves = 0
                        route.forEach { if case .move = $0 { moves += 1 } }
                        XCTAssertEqual(moves, 1, "AI→Gate→Folder must be one continuous path")
                        XCTAssertEqual(route.cgPath.currentPoint.x, layout.folders.anchors[index].x, accuracy: 0.001)
                        XCTAssertEqual(route.cgPath.currentPoint.y, layout.folders.anchors[index].y, accuracy: 0.001)
                        if !incoming {
                            var staticElements: [String] = [], routeElements: [String] = []
                            connector.forEach { staticElements.append(String(describing: $0)) }
                            route.forEach { routeElements.append(String(describing: $0)) }
                            XCTAssertEqual(Array(routeElements.suffix(staticElements.count - 1)), Array(staticElements.dropFirst()))
                        }
                    }
                }
            }
        }
    }

    func testEightFolderSecondRowUsesIndependentDirectCubicSweeps() {
        for width: CGFloat in [434, 574, 800] {
            let layout = GateMapLayout(width: width, appCount: 1, folderCount: 8)
            let layer = layout.folders
            let outer = layer.positions.indices.filter { layer.corridors[$0] != nil }
            var departureXs: Set<CGFloat> = []
            for index in outer {
                var path = Path()
                GateMapGeometry.appendFolder(to: &path, gate: layout.gate, destination: layer.anchors[index],
                                             corridor: layer.corridors[index])
                var elements: [Path.Element] = []
                path.forEach { elements.append($0) }
                XCTAssertEqual(elements.count, 2, "One direct curve, without intermediate trunks or junctions")
                guard case .move(let start) = elements.first,
                      case .curve(let end, let c1, let c2) = elements.last else {
                    XCTFail("Expected Gate origin and one cubic curve"); continue
                }
                XCTAssertEqual(start, layout.gate)
                XCTAssertEqual(end, layer.anchors[index])
                XCTAssertGreaterThan(abs(c1.x - layout.gate.x), 20, "Leave Gate with a directional tangent")
                XCTAssertGreaterThan(c1.y, start.y)
                XCTAssertLessThan(c2.y, end.y)
                departureXs.insert(c1.x)
            }
            XCTAssertEqual(departureXs.count, outer.count, "Each Folder has its own trajectory from Gate")
        }
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
