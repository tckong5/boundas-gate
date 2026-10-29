import Foundation
import XCTest
@testable import C2CManager

@MainActor
final class RobustnessTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func record(path: String, c2cID: String = "0123456789ab") -> WorkspaceRecord {
        WorkspaceRecord(name: URL(fileURLWithPath: path).lastPathComponent, path: path, c2cID: c2cID)
    }

    func testMissingWorkspaceFileStartsWithEmptyState() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(configURL: root.appendingPathComponent("workspaces.json"), automaticallyRefresh: false)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    func testMalformedWorkspaceFileFailsClosedAndPreservesBytes() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspaces.json")
        let original = Data("{not-json".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try WorkspaceStore(configURL: file, automaticallyRefresh: false))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAmbiguousFolderIdentityFailsClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspaces.json")
        let records = [record(path: "/Volumes/CaseSensitive/Foo"), record(path: "/Volumes/CaseSensitive/foo")]
        try JSONEncoder().encode(records).write(to: file)
        XCTAssertThrowsError(try WorkspaceStore(configURL: file, automaticallyRefresh: false))
    }

    func testUppercaseC2CIDFailsClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspaces.json")
        try JSONEncoder().encode([record(path: "/tmp/uppercase-folder", c2cID: "ABCDEF123456")]).write(to: file)
        XCTAssertThrowsError(try WorkspaceStore(configURL: file, automaticallyRefresh: false))
    }

    func testDuplicateWorkspaceRecordIDFailsClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspaces.json")
        var first = record(path: "/tmp/duplicate-id-a")
        var second = record(path: "/tmp/duplicate-id-b", c2cID: "abcdef123456")
        second.id = first.id
        first.name = "First"
        second.name = "Second"
        try JSONEncoder().encode([first, second]).write(to: file)
        XCTAssertThrowsError(try WorkspaceStore(configURL: file, automaticallyRefresh: false))
    }

    func testDuplicateCanonicalFolderPathFailsClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspaces.json")
        let records = [
            record(path: "/tmp/duplicate-canonical-folder", c2cID: "0123456789ab"),
            record(path: "/tmp/duplicate-canonical-folder/../duplicate-canonical-folder", c2cID: "abcdef123456")
        ]
        try JSONEncoder().encode(records).write(to: file)
        XCTAssertThrowsError(try WorkspaceStore(configURL: file, automaticallyRefresh: false))
    }

    func testCollisionGuardKeepsExistingIdentityAlgorithmAndRejectsDifferentPath() throws {
        let id = WorkspaceStore.c2cID(for: "/Volumes/CaseSensitive/Foo")
        XCTAssertEqual(id.count, 12)
        XCTAssertFalse(WorkspaceStore.hasIdentityCollision(canonicalPath: "/Volumes/CaseSensitive/Foo", c2cID: id,
                                                           in: [record(path: "/Volumes/CaseSensitive/Foo", c2cID: id)]))
        XCTAssertTrue(WorkspaceStore.hasIdentityCollision(canonicalPath: "/Volumes/CaseSensitive/foo", c2cID: id,
                                                          in: [record(path: "/Volumes/CaseSensitive/Foo", c2cID: id)]))
    }

    func testAddPathRejectsSyntheticIdentityCollisionWithoutChangingExistingFolder() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("Foo")
        let second = root.appendingPathComponent("foo")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(configURL: config, automaticallyRefresh: false,
                                       c2cIDResolver: { _ in "0123456789ab" },
                                       canonicalPathResolver: { URL(fileURLWithPath: $0).standardizedFileURL.path })
        XCTAssertTrue(store.addPath(first.path))
        XCTAssertFalse(store.addPath(second.path))
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces.first?.path, first.path)
    }

    func testRenameRollsBackWhenPersistenceFails() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        XCTAssertTrue(store.addPath(root.path))
        let originalName = try XCTUnwrap(store.workspaces.first?.name)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        store.rename(try XCTUnwrap(store.workspaces.first), to: "Changed")
        XCTAssertEqual(store.workspaces.first?.name, originalName)
    }

    func testDebugAndProductionProfilesRemainSeparated() {
        let support = URL(fileURLWithPath: "/Users/example/Library/Application Support")
        let production = AppDataPaths(support: support, profile: .production)
        let debug = AppDataPaths(support: support, profile: .debug)
        let test = AppDataPaths(support: support, profile: .newUserTest,
                                overrides: ["BOUNDAS_DATA_PROFILE": "production", "BOUNDAS_GATEWAY_DIR": "/unsafe"])
        XCTAssertEqual(production.directory.lastPathComponent, "Boundas Gate")
        XCTAssertEqual(production.c2c.lastPathComponent, "codex-with-chatgpt")
        XCTAssertEqual(debug.directory.lastPathComponent, "Boundas Gate Debug")
        XCTAssertEqual(debug.c2c, debug.directory.appendingPathComponent("c2c"))
        XCTAssertEqual(test.directory.lastPathComponent, "Boundas Gate New User Test")
        XCTAssertEqual(test.gateway, test.directory.appendingPathComponent("gateway"))
    }

    func testDebugChildEnvironmentUsesAllIsolatedStateDirectories() {
        let support = URL(fileURLWithPath: "/Users/example/Library/Application Support")
        let debug = AppDataPaths(support: support, profile: .debug,
                                 overrides: ["BOUNDAS_GATEWAY_DIR": "/production/gateway"])
        XCTAssertEqual(debug.gateway, debug.directory.appendingPathComponent("gateway"))
        let env = debug.childEnvironment(["BOUNDAS_GATEWAY_DIR": "/production/gateway"])
        XCTAssertEqual(env["BOUNDAS_WORKSPACES_FILE"], debug.workspaces.path)
        XCTAssertEqual(env["BOUNDAS_GATEWAY_DIR"], debug.gateway.path)
        XCTAssertEqual(env["BOUNDAS_STATE_DIR"], debug.tailscale.path)
        XCTAssertEqual(env["C2C_STATE_DIR"], debug.c2c.path)
    }

    func testDebugProductionOptInIsExplicitAndTestProfileWins() {
        XCTAssertEqual(AppDataPaths.resolveProfile(bundleMarker: nil,
                                                    environment: ["BOUNDAS_DATA_PROFILE": "production"],
                                                    debugBuild: true), .production)
        XCTAssertEqual(AppDataPaths.resolveProfile(bundleMarker: nil, environment: [:], debugBuild: true), .debug)
        XCTAssertEqual(AppDataPaths.resolveProfile(bundleMarker: "new-user-test",
                                                    environment: ["BOUNDAS_DATA_PROFILE": "production"],
                                                    debugBuild: true), .newUserTest)
        XCTAssertEqual(AppDataPaths.resolveProfile(bundleMarker: nil,
                                                    environment: ["BOUNDAS_DATA_PROFILE": "production"],
                                                    debugBuild: false), .production)
    }

    func testDebugPrepareDoesNotInspectOrMigrateLegacyProductionDirectory() throws {
        let support = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: support) }
        let legacy = support.appendingPathComponent("C2C Workspace Manager")
        let legacyWorkspaces = legacy.appendingPathComponent("workspaces.json")
        let original = Data("legacy-production-state".utf8)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try original.write(to: legacyWorkspaces)

        let debug = AppDataPaths(support: support, profile: .debug)
        try debug.prepare()

        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Boundas Gate").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: debug.workspaces.path))
        XCTAssertEqual(try Data(contentsOf: legacyWorkspaces), original)
    }

    func testSideRemovalNeverReportsCleanWhenFinalPersistenceFails() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("workspaces.json")
        let client = LifecycleClient()
        let store = try WorkspaceStore(configURL: config, client: client, automaticallyRefresh: false,
                                       sideGatewayFactory: { client.makeGateway($0.id, logFile: root.appendingPathComponent("diagnostics.log")) })
        XCTAssertTrue(store.addPath(folder.path))
        let record = try XCTUnwrap(store.workspaces.first)
        XCTAssertTrue(store.addToSideGates(record))
        client.removalObserved = { _ in
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        }
        await store.removeSideGate(record)
        let result = try XCTUnwrap(store.workspaces.first)
        XCTAssertEqual(result.sideGateRemovalState, .failed)
        XCTAssertTrue(result.belongsToSideGates)
    }

    func testEndpointMetadataRollsBackAsACompleteRecordWhenPersistenceFails() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("workspaces.json")
        let client = LifecycleClient()
        let store = try WorkspaceStore(configURL: config, client: client, automaticallyRefresh: false,
                                       sideGatewayFactory: { client.makeGateway($0.id, logFile: root.appendingPathComponent("diagnostics.log")) })
        XCTAssertTrue(store.addPath(folder.path))
        let record = try XCTUnwrap(store.workspaces.first)
        XCTAssertTrue(store.addToSideGates(record))
        client.running.insert(record.id)
        client.endpointURLs[record.id] = "https://one.example"
        let fixtureStatus = try JSONDecoder().decode(WorkspaceStatus.self, from: client.statusData(record.id))
        XCTAssertEqual(fixtureStatus.mcpURL, "https://one.example/mcp")
        await store.refreshAll()
        let persistedMetadata = try XCTUnwrap(store.workspaces.first)
        XCTAssertEqual(persistedMetadata.lastObservedMCPURL, "https://one.example/mcp")
        client.endpointURLs[record.id] = "https://two.example"
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        await store.refreshAll()
        XCTAssertEqual(store.workspaces.first, persistedMetadata)
    }

    func testFolderBookmarkPreservesIdentityWhenFolderIsRenamed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Before")
        let renamed = root.appendingPathComponent("After")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        XCTAssertTrue(store.addPath(old.path))
        let original = try XCTUnwrap(store.workspaces.first)
        XCTAssertNotNil(original.folderBookmark)
        try FileManager.default.moveItem(at: old, to: renamed)

        let restored = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        let moved = try XCTUnwrap(restored.workspaces.first)
        XCTAssertEqual(moved.id, original.id)
        XCTAssertEqual(moved.c2cID, original.c2cID)
        XCTAssertEqual(moved.path, WorkspaceStore.canonicalPath(renamed.path))
        XCTAssertTrue(moved.belongsToMainGate)
    }

    func testFolderBookmarkPreservesIdentityWhenFolderIsMoved() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let oldParent = root.appendingPathComponent("Old")
        let newParent = root.appendingPathComponent("New")
        let old = oldParent.appendingPathComponent("Folder")
        let movedPath = newParent.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newParent, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        XCTAssertTrue(store.addPath(old.path))
        let original = try XCTUnwrap(store.workspaces.first)
        try FileManager.default.moveItem(at: old, to: movedPath)

        let restored = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        let moved = try XCTUnwrap(restored.workspaces.first)
        XCTAssertEqual(moved.id, original.id)
        XCTAssertEqual(moved.c2cID, original.c2cID)
        XCTAssertEqual(moved.path, WorkspaceStore.canonicalPath(movedPath.path))
    }

    func testFolderBookmarkRepairsDeviceIdentityAfterRemountWithoutChangingFolderIdentity() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Remounted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        XCTAssertTrue(store.addPath(folder.path))
        let original = try XCTUnwrap(store.workspaces.first)
        let inode = try XCTUnwrap(original.folderFileIdentity?.split(separator: ":").last)
        var remounted = [original]
        remounted[0].folderFileIdentity = "999999:\(inode)"
        try JSONEncoder().encode(remounted).write(to: file)

        let restored = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        let repaired = try XCTUnwrap(restored.workspaces.first)
        XCTAssertEqual(repaired.id, original.id)
        XCTAssertEqual(repaired.c2cID, original.c2cID)
        XCTAssertEqual(repaired.folderFileIdentity, WorkspaceStore.fileIdentity(folder.path))
        XCTAssertEqual(repaired.folderIdentityRecovery?.previous, remounted[0].folderFileIdentity)
        XCTAssertEqual(repaired.folderIdentityRecovery?.current, repaired.folderFileIdentity)
        XCTAssertEqual(repaired.folderIdentityRecovery?.path, original.path)
        let saved = try JSONDecoder().decode([WorkspaceRecord].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.first?.folderIdentityRecovery, repaired.folderIdentityRecovery)
        XCTAssertFalse(repaired.needsFolderLocation)
    }

    func testMissingFolderRemainsUnresolvedUntilLocate() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Missing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        XCTAssertTrue(store.addPath(folder.path))
        let originalPath = try XCTUnwrap(store.workspaces.first?.path)
        try FileManager.default.removeItem(at: folder)
        let restored = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        XCTAssertEqual(restored.workspaces.first?.path, originalPath)
        XCTAssertEqual(restored.workspaces.first?.c2cID, store.workspaces.first?.c2cID)
    }

    func testReplacementAtOldPathFailsClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Folder")
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        XCTAssertTrue(store.addPath(old.path))
        try FileManager.default.moveItem(at: old, to: moved)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let restored = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        XCTAssertTrue(try XCTUnwrap(restored.workspaces.first).needsFolderLocation)
        XCTAssertNil(restored.workspaces.first?.folderIdentityRecovery)
    }

    func testLegacyRecordGainsStableReferenceWithoutChangingIdentity() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Legacy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspaces.json")
        let legacy = record(path: folder.path)
        try JSONEncoder().encode([legacy]).write(to: file)
        let restored = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        let value = try XCTUnwrap(restored.workspaces.first)
        XCTAssertEqual(value.id, legacy.id)
        XCTAssertEqual(value.c2cID, legacy.c2cID)
        XCTAssertNotNil(value.folderBookmark)
        XCTAssertNotNil(value.folderFileIdentity)
    }

    func testMainAndSideMembershipRemainUnchangedAfterRelocation() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Folder")
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        XCTAssertTrue(store.addPath(old.path))
        let original = try XCTUnwrap(store.workspaces.first)
        XCTAssertTrue(store.addToSideGates(original))
        try FileManager.default.moveItem(at: old, to: moved)

        let restored = try WorkspaceStore(configURL: file, automaticallyRefresh: false)
        let value = try XCTUnwrap(restored.workspaces.first)
        XCTAssertEqual(value.id, original.id)
        XCTAssertEqual(value.c2cID, original.c2cID)
        XCTAssertTrue(value.belongsToMainGate)
        XCTAssertTrue(value.belongsToSideGates)
        XCTAssertEqual(value.path, WorkspaceStore.canonicalPath(moved.path))
    }

    func testLocateFolderWithMatchingFileIdentityIsAllowed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original")
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        let identity = try XCTUnwrap(WorkspaceStore.fileIdentity(moved.path))
        XCTAssertNil(WorkspaceStore.relocationValidationError(originalPath: original.path,
                                                              bookmark: nil,
                                                              storedFileIdentity: identity,
                                                              selectedPath: moved.path))
    }

    func testLocateFolderWithMismatchingFileIdentityIsRejected() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        XCTAssertNotNil(WorkspaceStore.relocationValidationError(originalPath: root.appendingPathComponent("Missing").path,
                                                                  bookmark: nil,
                                                                  storedFileIdentity: "1:2",
                                                                  selectedPath: selected.path))
    }

    func testLegacyMissingFolderWithoutStableReferenceIsRejected() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let error = WorkspaceStore.relocationValidationError(originalPath: root.appendingPathComponent("Missing").path,
                                                             bookmark: nil,
                                                             storedFileIdentity: nil,
                                                             selectedPath: selected.path)
        XCTAssertEqual(error, "未能確認原本 Folder 身份；請先移除，再以新 Folder 加入。")
    }
}
