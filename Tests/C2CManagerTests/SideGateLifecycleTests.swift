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
    func reconnect(_ workspace: WorkspaceRecord) async throws -> StartResult {
        calls.append(("reconnect", workspace.id)); running.insert(workspace.id)
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
    func testAddedFolderUsesFilesystemCanonicalPathAndDeduplicatesAlias() throws {
        let (folder, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let alias = folder.appendingPathComponent("alias")
        let target = folder.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertTrue(store.addPath(alias.path))
        let resolved = try XCTUnwrap(realpath(target.path, nil))
        defer { free(resolved) }
        XCTAssertEqual(store.workspaces.first?.path, String(cString: resolved))
        XCTAssertTrue(store.addPath(target.path))
        XCTAssertEqual(store.workspaces.count, 1)
    }
    @MainActor
    private func fixture() throws -> (URL, WorkspaceStore, LifecycleClient) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let resolved = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(resolved) }
        let folder = URL(fileURLWithPath: String(cString: resolved))
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
        client.calls.removeAll()
        await store.reconnectAll()
        XCTAssertEqual(Set(client.calls.filter { $0.0 == "reconnect" }.map { $0.1 }), Set(store.sideGateWorkspaces.map(\.id)))
        XCTAssertFalse(client.calls.contains { $0.0 == "start" })
        await store.stopAll()
        XCTAssertEqual(store.runningCount, 0)
    }

    @MainActor
    func testNewFoldersOnlyJoinTheGateTheyWereAddedTo() throws {
        let (folder, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(store.addPath(folder.path))
        let main = try XCTUnwrap(store.mainGateWorkspaces.first)
        XCTAssertFalse(main.belongsToSideGates)
        let second = folder.appendingPathComponent("side-only")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        store.selectedID = nil
        XCTAssertTrue(store.addPath(second.path))
        let side = try XCTUnwrap(store.sideGateWorkspaces.first)
        XCTAssertFalse(side.belongsToMainGate)
        XCTAssertEqual(store.mainGateWorkspaces.map(\.id), [main.id])
        store.selectedID = SharedGatewayStore.selectionID
        XCTAssertTrue(store.addPath(second.path))
        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertEqual(Set(store.mainGateWorkspaces.map(\.id)), Set([main.id, side.id]))
        XCTAssertEqual(store.sideGateWorkspaces.map(\.id), [side.id])
    }

    @MainActor
    func testAddToSideRetainsMainAndMoveRevokesMainBeforeChangingMembership() async throws {
        let (folder, store, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(store.addPath(folder.path))
        let original = try XCTUnwrap(store.workspaces.first)
        XCTAssertTrue(store.addToSideGates(original))
        XCTAssertTrue(store.workspaces[0].belongsToMainGate)
        XCTAssertTrue(store.workspaces[0].belongsToSideGates)
        XCTAssertTrue(client.calls.isEmpty)
        var revoked = false
        let failed = await store.moveToSideGates(original) { sourceID in
            XCTAssertEqual(sourceID, original.id.uuidString.lowercased())
            XCTAssertTrue(store.workspaces[0].belongsToMainGate)
            return false
        }
        XCTAssertFalse(failed)
        XCTAssertTrue(store.workspaces[0].belongsToMainGate)
        let moved = await store.moveToSideGates(original) { _ in revoked = true; return true }
        XCTAssertTrue(moved); XCTAssertTrue(revoked)
        XCTAssertTrue(store.mainGateWorkspaces.isEmpty)
        let retained = try XCTUnwrap(store.sideGateWorkspaces.first)
        XCTAssertEqual(retained.id, original.id)
        XCTAssertEqual(retained.path, original.path)
        XCTAssertEqual(retained.name, original.name)
        XCTAssertTrue(client.calls.isEmpty)
        let restored = WorkspaceStore(configURL: folder.appendingPathComponent("records.json"), client: client, automaticallyRefresh: false)
        XCTAssertTrue(restored.mainGateWorkspaces.isEmpty)
        XCTAssertEqual(restored.sideGateWorkspaces.map(\.id), [original.id])
    }

    @MainActor
    func testReorderPersistsIndependentlyPerGateAndPreservesSelection() throws {
        let (folder, store, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["A", "B", "C"] {
            let child = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            XCTAssertTrue(store.addPath(child.path))
        }
        let original = store.mainGateWorkspaces
        for record in original { XCTAssertTrue(store.addToSideGates(record)) }
        store.selectedID = original[1].id
        store.moveFolders(from: IndexSet(integer: 2), to: 0, side: false)
        XCTAssertEqual(store.mainGateWorkspaces.map(\.id), [original[2].id, original[0].id, original[1].id])
        XCTAssertEqual(store.sideGateWorkspaces.map(\.id), original.map(\.id))
        store.moveFolders(from: IndexSet(integer: 0), to: 3, side: true)
        XCTAssertEqual(store.sideGateWorkspaces.map(\.id), [original[1].id, original[2].id, original[0].id])
        XCTAssertEqual(store.selectedID, original[1].id)
        let restored = WorkspaceStore(configURL: folder.appendingPathComponent("records.json"), client: client, automaticallyRefresh: false)
        XCTAssertEqual(restored.mainGateWorkspaces, store.mainGateWorkspaces)
        XCTAssertEqual(restored.sideGateWorkspaces, store.sideGateWorkspaces)
        XCTAssertTrue(client.calls.isEmpty)
    }

    @MainActor
    func testNewFoldersAppendAfterLegacyRecordsWithInterleavedMembership() throws {
        let (folder, _, client) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        var records = (0..<5).map { WorkspaceRecord(name: "Folder \($0)", path: folder.appendingPathComponent("\($0)").path, c2cID: String(format: "%012x", $0 + 1)) }
        for index in records.indices {
            records[index].mainGateAdded = index == 0 || index == 4
            records[index].sideGateAdded = index != 0 && index != 4
        }
        let config = folder.appendingPathComponent("records.json")
        try JSONEncoder().encode(records).write(to: config)
        let store = WorkspaceStore(configURL: config, client: client, automaticallyRefresh: false)
        let newFolder = folder.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        XCTAssertTrue(store.addPath(newFolder.path))
        XCTAssertEqual(store.mainGateWorkspaces.map(\.name), ["Folder 0", "Folder 4", "new"])
        XCTAssertEqual(store.sideGateWorkspaces.map(\.name), ["Folder 1", "Folder 2", "Folder 3"])
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
        let setupFile = GateUIContext.side(record).setupFile(in: folder)
        let sideSetup = AISetupStore(file: setupFile)
        XCTAssertTrue(sideSetup.begin(.claude, gateID: record.c2cID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: setupFile.path))
        let oldSide = loaded.sideGateway(for: record)
        XCTAssertTrue(oldSide === loaded.sideGateway(for: record))
        XCTAssertFalse(oldSide === gateway)
        await loaded.removeSideGate(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setupFile.path))
        let retained = try XCTUnwrap(loaded.workspaces.first)
        XCTAssertEqual(retained.id, record.id); XCTAssertEqual(retained.name, record.name)
        XCTAssertEqual(retained.path, record.path); XCTAssertEqual(retained.provider, .tailscale)
        XCTAssertFalse(retained.belongsToSideGates); XCTAssertNil(retained.configuredMCPURL)
        XCTAssertNil(retained.lastObservedMCPURL); XCTAssertEqual(retained.lastKnownMCPURL, record.configuredMCPURL)
        XCTAssertTrue(loaded.gateway === gateway)
        XCTAssertNil(gateway.status); XCTAssertNil(gateway.operation)
        let restored = WorkspaceStore(configURL: config, client: client, automaticallyRefresh: false)
        XCTAssertEqual(restored.workspaces, loaded.workspaces)
        loaded.selectedID = nil
        XCTAssertTrue(loaded.addPath(folder.path))
        XCTAssertTrue(loaded.workspaces[0].belongsToSideGates)
        XCTAssertNil(loaded.workspaces[0].configuredMCPURL)
        XCTAssertFalse(oldSide === loaded.sideGateway(for: loaded.workspaces[0]))
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
