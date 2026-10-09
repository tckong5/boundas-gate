import XCTest
@testable import C2CManager

final class MainMigrationRoutingTests: XCTestCase {
    func testPendingMainPrimaryActionsContinueMigration() {
        for action: SecureAccessPresentation.Action in [.setUp, .signIn, .approve, .repair] {
            XCTAssertEqual(SecureAccessPresentation.migrationAction(for: action, isSideGate: false, pending: true), "migrate-shared")
        }
    }
    func testSideAndNonPendingActionsKeepExistingRouting() {
        for action: SecureAccessPresentation.Action in [.setUp, .signIn, .approve, .repair, .repairDNS, .recheck] {
            XCTAssertNil(SecureAccessPresentation.migrationAction(for: action, isSideGate: true, pending: true))
            XCTAssertNil(SecureAccessPresentation.migrationAction(for: action, isSideGate: false, pending: false))
        }
        XCTAssertNil(SecureAccessPresentation.migrationAction(for: .recheck, isSideGate: false, pending: true))
        XCTAssertNil(SecureAccessPresentation.migrationAction(for: .repairDNS, isSideGate: false, pending: true))
    }
}
