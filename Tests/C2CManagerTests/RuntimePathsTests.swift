import Foundation
import XCTest
@testable import C2CManager

final class RuntimePathsTests: XCTestCase {
    func testMissingBundledResourcesNeverResolveToDeveloperTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("developer/Resources/Gateway")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("developer file".utf8).write(to: source.appendingPathComponent("launcher.mjs"))
        let paths = RuntimePaths(resources: root.appendingPathComponent("App.app/Contents/Resources"), home: root, applicationBundle: true)
        XCTAssertTrue(paths.bundled)
        XCTAssertFalse(paths.cli.contains("codex-with-chatgpt"))
        XCTAssertThrowsError(try paths.resource("Gateway/launcher.mjs", developerRoot: root.appendingPathComponent("developer"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Gateway/launcher.mjs"))
        }
        XCTAssertNil(paths.bundledNode)
        XCTAssertFalse(RuntimePaths(resources: nil, home: root, applicationBundle: true).cli.contains("codex-with-chatgpt"))
    }
    func testNewUserProfileSeparatesEveryPersistentStore() {
        let support = URL(fileURLWithPath: "/Users/example/Library/Application Support")
        let production = AppDataPaths(support: support, newUserTest: false)
        let trial = AppDataPaths(support: support, newUserTest: true)
        XCTAssertNotEqual(trial.workspaces, production.workspaces)
        XCTAssertNotEqual(trial.gateway, production.gateway)
        XCTAssertNotEqual(trial.c2c, production.c2c)
        XCTAssertEqual(trial.c2cLogs, trial.c2c.appendingPathComponent("logs"))
        let inherited = ["BOUNDAS_WORKSPACES_FILE": production.workspaces.path,
                         "BOUNDAS_GATEWAY_DIR": production.gateway.path,
                         "BOUNDAS_STATE_DIR": "/real/tailscale", "C2C_STATE_DIR": production.c2c.path,
                         "PATH": "/usr/bin"]
        let child = trial.childEnvironment(inherited)
        XCTAssertEqual(child["BOUNDAS_WORKSPACES_FILE"], trial.workspaces.path)
        XCTAssertEqual(child["BOUNDAS_GATEWAY_DIR"], trial.gateway.path)
        XCTAssertEqual(child["BOUNDAS_STATE_DIR"], trial.directory.appendingPathComponent("tailscale").path)
        XCTAssertEqual(child["C2C_STATE_DIR"], trial.c2c.path)
        XCTAssertEqual(child["PATH"], inherited["PATH"])
        XCTAssertEqual(production.childEnvironment(inherited), inherited)
        XCTAssertEqual(production.workspaces.path, support.appendingPathComponent("C2C Workspace Manager/workspaces.json").path)
        XCTAssertEqual(production.c2c.path, support.appendingPathComponent("codex-with-chatgpt").path)
    }

    func testDeveloperBuildFallsBackToCurrentUsersBackend() {
        let paths = RuntimePaths(resources: nil, home: URL(fileURLWithPath: "/Users/example"))
        XCTAssertFalse(paths.bundled)
        XCTAssertEqual(paths.cli, "/Users/example/codex-with-chatgpt/bin/c2c.js")
        XCTAssertNil(paths.bundledNode)
    }

    func testPackagedRuntimeDoesNotDependOnTheDevelopersHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("Runtime/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        try Data("test".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        let paths = RuntimePaths(resources: root, home: URL(fileURLWithPath: "/Users/no-backend"))
        XCTAssertTrue(paths.bundled)
        XCTAssertEqual(paths.bundledNode, node.path)
        XCTAssertEqual(paths.backend, root.appendingPathComponent("Runtime/C2C").path)
        XCTAssertFalse(paths.cli.contains("/Users/no-backend"))
    }

    func testEmbeddedLoginLinkRejectsUnexpectedHosts() throws {
        let unsafe = Data(#"{"state":"login","message":"test","loginURL":"https://example.com/login"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(EmbeddedConnectionSetup.self, from: unsafe).actionURL)
        let safe = Data(#"{"state":"login","message":"test","loginURL":"https://login.tailscale.com/a/test"}"#.utf8)
        XCTAssertNotNil(try JSONDecoder().decode(EmbeddedConnectionSetup.self, from: safe).actionURL)
    }
}
