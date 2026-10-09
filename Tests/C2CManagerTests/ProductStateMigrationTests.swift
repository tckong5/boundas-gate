import Foundation
import XCTest
@testable import C2CManager

final class ProductStateMigrationTests: XCTestCase {
    private func fixture(_ action: (URL, URL, URL) throws -> Void) throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try action(support, support.appendingPathComponent("C2C Workspace Manager"), support.appendingPathComponent("Boundas Gate"))
    }
    private func write(_ value: String, to url: URL, mode: Int = 0o600) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    func testFreshInstallUsesCanonicalPathWithoutInventingIdentity() throws {
        try fixture { support, _, destination in
            let paths = AppDataPaths(support: support, newUserTest: false)
            try paths.prepare()
            XCTAssertEqual(paths.directory, destination)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(paths.childEnvironment([:])["BOUNDAS_STATE_DIR"], destination.appendingPathComponent("tailscale").path)
        }
    }
    func testLegacyOnlyPreservesIdentityAuthorizationEndpointAndPermissions() throws {
        try fixture { support, legacy, destination in
            let files = ["workspaces.json": "[{\"id\":\"folder-a\",\"sideGateAdded\":true}]",
                         "gateway/config.json": "{\"id\":\"123456789abc\",\"stableMCPURL\":\"https://example.ts.net/mcp\"}",
                         "gateway/oauth.json": "fixture-authorization",
                         "ai-setup.completed.json": "true",
                         "tailscale/state.json": "fixture-device-identity"]
            for (file, value) in files { try write(value, to: legacy.appendingPathComponent(file)) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacy.path)
            try ProductStateMigration.prepare(support: support)
            for (file, value) in files {
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(file)), Data(value.utf8))
                XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent(file)), Data(value.utf8))
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(file).path)[.posixPermissions] as? Int, 0o600)
            }
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int, 0o700)
            try ProductStateMigration.prepare(support: support) { _, _ in XCTFail("Repeated migration") }
        }
    }
    func testExistingNewProfileNeverMergesOrOverwritesLegacy() throws {
        try fixture { support, legacy, destination in
            try write("legacy-id", to: legacy.appendingPathComponent("gateway/config.json"))
            try write("current-id", to: destination.appendingPathComponent("gateway/config.json"))
            try write("legacy-only", to: legacy.appendingPathComponent("workspaces.json"))
            try ProductStateMigration.prepare(support: support) { _, _ in XCTFail("Existing state must win") }
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("gateway/config.json")), "current-id")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("workspaces.json").path))
        }
    }
    func testFailureRemovesPartialCopyAndCannotStartFreshIdentity() throws {
        try fixture { support, legacy, destination in
            try write("existing-id", to: legacy.appendingPathComponent("gateway/config.json"))
            XCTAssertThrowsError(try ProductStateMigration.prepare(support: support) { _, staging in
                try self.write("partial", to: staging.appendingPathComponent("workspaces.json"))
                throw CocoaError(.fileWriteOutOfSpace)
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("gateway/config.json")), "existing-id")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: support.path).contains { $0.hasPrefix(".boundas-migration-") })
            try ProductStateMigration.prepare(support: support)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("gateway/config.json").path))
        }
    }
    func testLiveLegacyRuntimeBlocksMigration() throws {
        try fixture { support, legacy, destination in
            try write("{\"pid\":\(ProcessInfo.processInfo.processIdentifier)}", to: legacy.appendingPathComponent("gateway/runtime.json"))
            XCTAssertThrowsError(try ProductStateMigration.prepare(support: support))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
    func testNewUserProfileNeverReadsOrMigratesProductionEvenWithInheritedOverrides() throws {
        try fixture { support, legacy, destination in
            try write("legacy-id", to: legacy.appendingPathComponent("gateway/config.json"))
            let trial = AppDataPaths(support: support, newUserTest: true, overrides: ["BOUNDAS_GATEWAY_DIR": legacy.path, "C2C_STATE_DIR": legacy.path])
            try trial.prepare()
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let env = trial.childEnvironment(["BOUNDAS_STATE_DIR": legacy.path])
            for key in ["BOUNDAS_GATEWAY_DIR", "BOUNDAS_WORKSPACES_FILE", "BOUNDAS_STATE_DIR", "C2C_STATE_DIR"] {
                XCTAssertTrue(env[key]!.hasPrefix(trial.directory.path + "/"))
            }
        }
    }
    func testProductionOverridesAreResolvedByParentAndChildrenTogether() throws {
        try fixture { support, _, _ in
            let overrides = ["BOUNDAS_GATEWAY_DIR": "/custom/gateway", "BOUNDAS_WORKSPACES_FILE": "/custom/workspaces.json",
                             "BOUNDAS_STATE_DIR": "/custom/tailscale", "C2C_STATE_DIR": "/custom/c2c"]
            let paths = AppDataPaths(support: support, newUserTest: false, overrides: overrides)
            XCTAssertEqual(paths.gateway.path, overrides["BOUNDAS_GATEWAY_DIR"])
            XCTAssertEqual(paths.workspaces.path, overrides["BOUNDAS_WORKSPACES_FILE"])
            XCTAssertEqual(paths.childEnvironment([:]), overrides)
        }
    }
    func testInvalidDestinationOrSymlinkCannotFallThroughToFreshProfile() throws {
        try fixture { support, legacy, destination in
            try write("legacy", to: legacy.appendingPathComponent("workspaces.json"))
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: legacy)
            XCTAssertThrowsError(try ProductStateMigration.prepare(support: support))
            XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("workspaces.json")), "legacy")
        }
    }
}
