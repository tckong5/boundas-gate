import XCTest
@testable import C2CManager

final class UpdateConfigurationTests: XCTestCase {
    private func info(_ feed: String) -> [String: Any] {
        ["SUPublicEDKey": UpdateConfiguration.publicKey, "SUFeedURL": feed]
    }
    func testProductionRequiresConfiguredHTTPSFeedAndKey() {
        XCTAssertNil(UpdateConfiguration.feed(info: [:], profile: .production))
        for feed in ["http://example.com/appcast.xml", "https://localhost/appcast.xml", "https://user:secret@example.com/feed"] {
            XCTAssertNil(UpdateConfiguration.feed(info: info(feed), profile: .production))
        }
        XCTAssertEqual(UpdateConfiguration.feed(info: info("https://example.com/appcast.xml"), profile: .production)?.host, "example.com")
        XCTAssertNil(UpdateConfiguration.feed(info: ["SUPublicEDKey": "invalid", "SUFeedURL": "https://example.com/feed"], profile: .production))
    }
    func testDevelopmentNeverInheritsProductionFeed() {
        for profile: AppDataPaths.Profile in [.debug, .newUserTest] {
            XCTAssertNil(UpdateConfiguration.feed(info: info("https://example.com/appcast.xml"), profile: profile))
            var configuration = info("https://example.com/appcast.xml")
            configuration["BoundasGateTestFeedURL"] = "http://127.0.0.1:8765/appcast.xml"
            XCTAssertEqual(UpdateConfiguration.feed(info: configuration, profile: profile)?.port, 8765)
            configuration["BoundasGateTestFeedURL"] = "http://example.com/feed"
            XCTAssertNil(UpdateConfiguration.feed(info: configuration, profile: profile))
        }
    }
    @MainActor func testRawExecutableDoesNotStartUpdater() {
        XCTAssertFalse(AppUpdater().canCheckForUpdates)
    }
}
