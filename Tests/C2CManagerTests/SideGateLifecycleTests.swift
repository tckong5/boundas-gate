import XCTest
@testable import C2CManager

@MainActor
private final class LifecycleClient: SideGateClient {
    var calls: [(String, UUID)] = []
    var running: Set<UUID> = []
    var failRemoval = false
    var removalObserved: ((WorkspaceRecord) -> Void)?
    func status(for workspace: WorkspaceRecord) async throws -> WorkspaceStatus {
        calls.append(("status", workspace.id))
        return .init(running: running.contains(workspace.id), state: "stopped", reason: nil,
                     port: nil, pid: nil, publicUrl: nil, tunnel: nil, tokenCount: 0, pairingActive: false)
    }
    func start(_ workspace: WorkspaceRecord) async throws -> StartResult {
        calls.append(("start", workspace.id)); running.insert(workspace.id)
        return .init(ok: true, mcpUrl: nil, connectorName: nil, error: nil, message: nil)
    }
    func stop(_ workspace: WorkspaceRecord) async throws { calls.append(("stop", workspace.id)); running.remove(workspace.id) }
    func pair(_ workspace: WorkspaceRecord) async throws -> PairingCode { .init(value: "TEST", expiresAt: .distantFuture) }
    func unpair(_ workspace: WorkspaceRecord) async throws {}
    func tailscaleSetup() async throws -> TailscaleSetup { .init(state: "ready", hostname: nil, message: "") }
    func decommission(_ workspace: WorkspaceRecord) async throws {
        calls.append(("remove", workspace.id)); removalObserved?(workspace)
        if failRemoval { throw C2CClientError.commandFailed("test cleanup failure") }
        running.remove(workspace.id)
    }
}

final class SideGateLifecycleTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (URL, WorkspaceStore, LifecycleClient) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let client = LifecycleClient()
        let store = WorkspaceStore(configURL: folder.appendingPathComponent("records.json"), client: client,
                                   automaticallyRefresh: false)
        return (folder, store, client)
    }

    @MainActor
    func testMainOnlyFoldersNeverEnterSideLifecycleOrCounts() async throws {
        let (folder, store, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(store.addPath(folder.path))
        let record = try XCTUnwrap(store.workspaces.first)
        XCTAssertFalse(record.belongsToSideGates)
        await store.refreshAll(); await store.startAll(); await store.stopAll(); await store.reconnectAll()
        await store.start(record); await store.stop(record); await store.restart(record)
        await store.removeSideGate(record)
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertEqual(store.runningCount, 0)
        XCTAssertEqual(store.healthyConnectionCount, 0)
        XCTAssertEqual(store.workspaces.count, 1)
    }

    @MainActor
    func testExistingAndNewFoldersCanBeAddedToSideGates() async throws {
        let (folder, store, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(store.addPath(folder.path))
        let identity = try XCTUnwrap(store.workspaces.first).id
        store.selectedID = nil
        XCTAssertTrue(store.addPath(folder.path))
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.sideGateWorkspaces.first?.id, identity)
        let second = folder.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        XCTAssertTrue(store.addPath(second.path))
        XCTAssertEqual(store.sideGateWorkspaces.count, 2)
        await store.startAll()
        XCTAssertEqual(Set(client.calls.filter { $0.0 == "start" }.map { $0.1 }), Set(store.workspaces.map(\.id)))
        XCTAssertEqual(store.runningCount, 2)
        await store.stopAll()
        XCTAssertEqual(store.runningCount, 0)
    }

    @MainActor
    func testRemovalPreservesFolderProviderMainGateAndClearsSideEndpoint() async throws {
        let (folder, _, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var record = WorkspaceRecord(name: "Display", path: folder.path, c2cID: "abcdef123456")
        record.sideGateAdded = true; record.connectionProvider = .tailscale
        record.configuredMCPURL = "https://mac.example.ts.net/c2c/abcdef123456/mcp"
        record.lastObservedMCPURL = record.configuredMCPURL
        let config = folder.appendingPathComponent("records.json")
        try JSONEncoder().encode([record]).write(to: config)
        let gateway = SharedGatewayStore(automaticallyRefresh: false)
        let loaded = WorkspaceStore(configURL: config, client: client, gateway: gateway, automaticallyRefresh: false)
        client.removalObserved = { item in
            XCTAssertEqual(item.sideGateRemovalState, .removing)
            XCTAssertTrue(item.belongsToSideGates)
            XCTAssertFalse(item.canOperateSideGate)
        }
        await loaded.removeSideGate(record)
        let retained = try XCTUnwrap(loaded.workspaces.first)
        XCTAssertEqual(retained.id, record.id); XCTAssertEqual(retained.name, record.name)
        XCTAssertEqual(retained.path, record.path); XCTAssertEqual(retained.provider, .tailscale)
        XCTAssertFalse(retained.belongsToSideGates); XCTAssertNil(retained.configuredMCPURL)
        XCTAssertNil(retained.lastObservedMCPURL); XCTAssertEqual(retained.lastKnownMCPURL, record.configuredMCPURL)
        XCTAssertTrue(loaded.gateway === gateway)
        XCTAssertNil(gateway.status)
        let restored = WorkspaceStore(configURL: config, client: client, automaticallyRefresh: false)
        XCTAssertEqual(restored.workspaces, loaded.workspaces)
        loaded.selectedID = nil
        XCTAssertTrue(loaded.addPath(folder.path))
        XCTAssertTrue(loaded.workspaces[0].belongsToSideGates)
        XCTAssertNil(loaded.workspaces[0].configuredMCPURL)
    }

    @MainActor
    func testFailedRemovalRemainsVisibleAndRetryableAcrossRestart() async throws {
        let (folder, store, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        store.selectedID = nil; XCTAssertTrue(store.addPath(folder.path))
        let record = store.workspaces[0]
        client.failRemoval = true
        await store.removeSideGate(record)
        XCTAssertEqual(store.sideGateWorkspaces.count, 1)
        XCTAssertEqual(store.workspaces[0].sideGateRemovalState, .failed)
        client.calls.removeAll()
        await store.startAll(); await store.refreshAll(); await store.reconnectAll()
        XCTAssertTrue(client.calls.isEmpty)
        let restored = WorkspaceStore(configURL: folder.appendingPathComponent("records.json"), client: client, automaticallyRefresh: false)
        XCTAssertEqual(restored.workspaces[0].sideGateRemovalState, .failed)
        client.failRemoval = false
        await restored.removeSideGate(restored.workspaces[0])
        XCTAssertTrue(restored.sideGateWorkspaces.isEmpty)
        XCTAssertEqual(restored.workspaces.count, 1)
    }

    @MainActor
    func testInterruptedRemovalRequiresRetryRatherThanAutomaticRestart() throws {
        let (folder, _, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var record = WorkspaceRecord(name: "Folder", path: folder.path, c2cID: "abcdef123456")
        record.sideGateAdded = true; record.sideGateRemovalState = .removing
        let config = folder.appendingPathComponent("records.json")
        try JSONEncoder().encode([record]).write(to: config)
        let restored = WorkspaceStore(configURL: config, client: client, automaticallyRefresh: false)
        XCTAssertEqual(restored.workspaces[0].sideGateRemovalState, .failed)
        XCTAssertFalse(restored.workspaces[0].canOperateSideGate)
    }

    @MainActor
    func testProviderPreferenceAloneDoesNotCreateLegacySideMembership() throws {
        let (folder, _, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var record = WorkspaceRecord(name: "Folder", path: folder.path, c2cID: "abcdef123456")
        record.sideGateAdded = nil; record.connectionProvider = .tailscale
        let config = folder.appendingPathComponent("records.json")
        try JSONEncoder().encode([record]).write(to: config)
        let restored = WorkspaceStore(configURL: config, client: client, automaticallyRefresh: false)
        XCTAssertFalse(restored.workspaces[0].belongsToSideGates)
        XCTAssertEqual(restored.workspaces[0].provider, .tailscale)
    }
}
