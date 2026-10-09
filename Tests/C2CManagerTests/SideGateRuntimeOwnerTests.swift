import Combine
import XCTest
@testable import C2CManager

@MainActor
final class SideGateRuntimeOwnerTests: XCTestCase {
    private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }

    private func fixture() throws -> (URL, WorkspaceStore, LifecycleClient, [WorkspaceRecord]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let client = LifecycleClient()
        let log = root.appendingPathComponent("diagnostics.log")
        let main = client.makeGateway(SharedGatewayStore.selectionID, logFile: log)
        let store = try WorkspaceStore(configURL: root.appendingPathComponent("folders.json"), client: client,
                                       gateway: main, automaticallyRefresh: false,
                                       sideGatewayFactory: { client.makeGateway($0.id, logFile: log) })
        for name in ["Side A", "Side B"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            XCTAssertTrue(store.addPath(folder.path))
            XCTAssertTrue(store.addToSideGates(store.workspaces.last!))
        }
        return (root, store, client, store.sideGateWorkspaces)
    }

    func testSidebarDetailAndRepeatedLookupShareOneOwner() throws {
        let (root, store, client, records) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = store.sideGateway(for: records[0])
        let detail = WorkspaceDetail(store: store, workspace: records[0])
        let sidebar = SideGateLifecycleDot(store: store, gateway: store.sideGateway(for: records[0]), workspace: records[0])
        XCTAssertTrue(first === store.sideGateway(for: records[0]))
        XCTAssertTrue(detail.gateway === first)
        XCTAssertTrue(sidebar.gateway === first)
        XCTAssertFalse(first === store.gateway)
        XCTAssertEqual(client.createdSideGateIDs, [records[0].id])
    }

    func testCountsUseCachedOwnersAndPublishChangesWithoutCreatingStores() async throws {
        let (root, store, client, records) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(store.runningCount, 0); XCTAssertEqual(store.healthyConnectionCount, 0)
        XCTAssertTrue(client.createdSideGateIDs.isEmpty)
        let connection = store.sideGateway(for: records[0])
        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        client.running.insert(records[0].id)
        await connection.refresh()
        XCTAssertEqual(store.runningCount, 1)
        XCTAssertEqual(store.healthyConnectionCount, 1)
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertEqual(client.createdSideGateIDs, [records[0].id])
        _ = subscription
    }

    func testBackgroundPassObservesEachSideOnceWhileMainIsSelected() async throws {
        let (root, store, client, records) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(store.selectedID, SharedGatewayStore.selectionID)
        await store.refreshAll()
        XCTAssertEqual(client.calls.map(\.0), ["status", "status"])
        XCTAssertEqual(Set(client.calls.map(\.1)), Set(records.map(\.id)))
        for record in records { XCTAssertTrue(store.sideGateway(for: record).statusConfirmed) }
        XCTAssertNil(store.gateway.status)
    }

    func testConcurrentObservationReusesTheOwnersInFlightCheck() async throws {
        let (root, store, client, records) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = store.sideGateway(for: records[0])
        client.heldStatusID = records[0].id
        let first = Task { await owner.refresh(background: true) }
        while client.statusContinuation == nil { await Task.yield() }
        await owner.refresh()
        XCTAssertEqual(client.calls.filter { $0.1 == records[0].id && $0.0 == "status" }.count, 1)
        XCTAssertTrue(owner.checking)
        client.statusContinuation?.resume(returning: try client.statusData(records[0].id))
        client.statusContinuation = nil
        await first.value
        XCTAssertTrue(owner.statusConfirmed)
    }

    func testPairingAndAuthorizationStayGateLocalAcrossNavigationNewCodeCancelAndExpiry() async throws {
        let (root, store, client, records) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainID = SharedGatewayStore.selectionID
        client.running.formUnion([mainID, records[0].id, records[1].id])
        let a = store.sideGateway(for: records[0]); let b = store.sideGateway(for: records[1])
        expectTrue(await store.gateway.perform("pair"))
        expectTrue(await a.perform("pair")); expectTrue(await b.perform("pair"))
        let aPair = try XCTUnwrap(a.pairing); let bPair = try XCTUnwrap(b.pairing)
        let mainPair = try XCTUnwrap(store.gateway.pairing)
        XCTAssertNotEqual(aPair.sessionID, bPair.sessionID); XCTAssertNotEqual(aPair.sessionID, mainPair.sessionID)
        store.selectedID = mainID; await store.refreshAll(); store.selectedID = records[0].id
        XCTAssertEqual(a.pairing?.sessionID, aPair.sessionID)
        XCTAssertEqual(b.pairing?.sessionID, bPair.sessionID)
        expectTrue(await a.perform("pair"))
        XCTAssertNotEqual(a.pairing?.sessionID, aPair.sessionID)
        expectTrue(await a.perform("cancel-setup", sessionIDs: [a.pairing!.sessionID!]))
        XCTAssertNil(a.pairing); XCTAssertEqual(b.pairing?.sessionID, bPair.sessionID)
        XCTAssertEqual(store.gateway.pairing?.sessionID, mainPair.sessionID)
        client.pairLifetime = -1
        expectTrue(await a.perform("pair")); XCTAssertNil(a.pairing)
        client.authorizedClients[mainID] = "Main client"; client.authorizedClients[records[1].id] = "Side B client"
        await store.gateway.refresh(); await store.refreshAll()
        XCTAssertEqual(store.gateway.status?.aiConnections?.map(\.clientID), ["Main client"])
        XCTAssertEqual(a.status?.aiConnections?.count, 0)
        XCTAssertEqual(b.status?.aiConnections?.map(\.clientID), ["Side B client"])
    }

    func testRemovalDiscardsOwnerAndLateStatusCannotResurrectItOnReAdd() async throws {
        let (root, store, client, records) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = records[0]; let old = store.sideGateway(for: record)
        client.running.insert(record.id)
        expectTrue(await old.perform("pair"))
        let stale = try client.statusData(record.id)
        client.heldStatusID = record.id
        let observation = Task { await store.refreshAll() }
        while client.statusContinuation == nil { await Task.yield() }
        await store.removeSideGate(record)
        XCTAssertNil(store.sideGateConnections[record.id])
        XCTAssertNil(old.pairing); XCTAssertNil(old.status); XCTAssertFalse(old.statusConfirmed)
        _ = store.sideGateway(for: record) // A stale UI lookup cannot reinsert it.
        XCTAssertNil(store.sideGateConnections[record.id])
        XCTAssertTrue(store.addToSideGates(store.workspaces.first { $0.id == record.id }!))
        let fresh = store.sideGateway(for: record)
        XCTAssertFalse(old === fresh); XCTAssertNil(fresh.pairing); XCTAssertNil(fresh.status)
        client.statusContinuation?.resume(returning: stale); client.statusContinuation = nil
        await observation.value
        XCTAssertTrue(store.sideGateConnections[record.id] === fresh)
        XCTAssertNil(old.status); XCTAssertNil(old.pairing)
        XCTAssertNil(fresh.status); XCTAssertNil(fresh.pairing)
        let callsBefore = client.calls.count
        await old.refresh(); expectFalse(await old.perform("start-local")); expectFalse(await old.perform("pair"))
        XCTAssertEqual(client.calls.count, callsBefore)
        await fresh.refresh(); XCTAssertEqual(fresh.status?.running, false)
        XCTAssertEqual(store.workspaces.first { $0.id == record.id }?.belongsToMainGate, true)
    }

    func testFailedRemovalKeepsRetryRowButRetiresRuntimeOwnerUntilSuccessfulRetry() async throws {
        let (root, store, client, records) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = records[0]; let old = store.sideGateway(for: record)
        client.running.insert(record.id)
        expectTrue(await old.perform("pair"))
        client.failRemoval = true
        await store.removeSideGate(record)
        XCTAssertEqual(store.workspaces.first { $0.id == record.id }?.sideGateRemovalState, .failed)
        XCTAssertTrue(store.sideGateConnections[record.id] === old)
        XCTAssertNil(old.pairing); XCTAssertNil(old.status)
        client.calls.removeAll(); await store.refreshAll()
        XCTAssertFalse(client.calls.contains { $0.1 == record.id })
        client.failRemoval = false
        await store.removeSideGate(record)
        XCTAssertNil(store.sideGateConnections[record.id])
    }

    func testRemovingGateCannotRunAnyRuntimeActionWhileDecommissionIsInFlight() async throws {
        let (root, store, client, records) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = records[0]; let owner = store.sideGateway(for: record)
        client.holdDecommission = true
        let removal = Task { await store.removeSideGate(record) }
        while client.decommissionContinuation == nil { await Task.yield() }
        XCTAssertEqual(store.workspaces.first { $0.id == record.id }?.sideGateRemovalState, .removing)
        expectFalse(await owner.perform("pair")); expectFalse(await owner.perform("start-local"))
        await owner.refresh(); await store.toggleSideGate(record)
        XCTAssertEqual(client.calls.filter { $0.1 == record.id }.map(\.0), ["remove"])
        client.decommissionContinuation?.resume(); client.decommissionContinuation = nil
        await removal.value
        XCTAssertNil(store.sideGateConnections[record.id])
    }
}
