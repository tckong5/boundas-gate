import Foundation
import XCTest
@testable import C2CManager

final class GatewayDiagnosticsLogTests: XCTestCase {
    func testFolderPasscodeAndAccessKeyAreNeverLogged() {
        let code = "BG-B0EA-B1A3-3D4E-A6F6-37B6-58DF"
        let text = GatewayDiagnosticsLog.redacted("failed code \(code) api_key=shortkey ?access_key=shortaccess")
        XCTAssertFalse(text.contains(code))
        XCTAssertFalse(text.contains("shortkey"))
        XCTAssertFalse(text.contains("shortaccess"))
    }
    func testUnderlyingStderrAndExitStatusPreservedWithoutSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("gateway.log")
        GatewayDiagnosticsLog.record(.init(code: 7, output: "raw stdout secret", error: "Error: missing module\n at server.mjs:20\nAuthorization: Bearer abcdef\n{\"client_secret\":\"shortsecret\"}\npairing_code=ABCD-EFGH\nhttps://user:password@example.com\n?code=privatecode&next=ok"), action: "status", file: file)
        let log = try String(contentsOf: file)
        XCTAssertTrue(log.contains("exit=7")); XCTAssertTrue(log.contains("missing module")); XCTAssertTrue(log.contains("server.mjs:20"))
        for secret in ["abcdef", "shortsecret", "ABCD-EFGH", "password", "privatecode", "raw stdout"] { XCTAssertFalse(log.contains(secret), secret) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
