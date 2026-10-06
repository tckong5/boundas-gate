import Foundation
import XCTest
@testable import C2CManager

final class RuntimePathsTests: XCTestCase {
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
