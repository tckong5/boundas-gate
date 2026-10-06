import XCTest
@testable import C2CManager

final class ConnectionGuidanceTests: XCTestCase {
    private var workspace: WorkspaceRecord { .init(name: "Canto", path: "/tmp/canto", c2cID: "canto") }
    private var status: WorkspaceStatus {
        .init(running: true, state: "running", reason: nil, port: 49347, pid: 1,
              publicUrl: "https://current.trycloudflare.com", tunnel: .init(running: true, url: "https://current.trycloudflare.com"),
              tokenCount: 1, pairingActive: false)
    }
    private func diagnostics(publicEndpoint: ConnectionCheck = .success("ok")) -> ConnectionDiagnostics {
        .init(checkedAt: Date(), bridge: .success("ok"), localMCP: .success("ok"),
              publicEndpoint: publicEndpoint, publicMCP: .success("ok"), address: .success("ok"))
    }

    func testDeadPublicURLOffersRepairEvenWhenProcessRuns() {
        let guidance = ConnectionGuidance.make(workspace: workspace, status: status,
                                              diagnostics: diagnostics(publicEndpoint: .failure("DNS")), checking: false, folderExists: true)
        XCTAssertEqual(guidance.action, .repair)
        XCTAssertTrue(guidance.needsAttention)
        XCTAssertEqual(guidance.button, "幫我修復連線…")
    }

    func testHealthyMacWithStaleChatGPTURLOffersSetupInsteadOfAnotherRestart() {
        var workspace = workspace
        workspace.configuredMCPURL = "https://old.trycloudflare.com/mcp"
        let guidance = ConnectionGuidance.make(workspace: workspace, status: status, diagnostics: diagnostics(), checking: false, folderExists: true)
        XCTAssertEqual(guidance.action, .setup)
        XCTAssertTrue(guidance.needsAttention)
    }

    func testHealthyUnconfirmedConnectionDoesNotClaimChatGPTWorks() {
        let guidance = ConnectionGuidance.make(workspace: workspace, status: status, diagnostics: diagnostics(), checking: false, folderExists: true)
        XCTAssertEqual(guidance.action, .setup)
        XCTAssertEqual(guidance.title, "Mac 已準備好，下一步設定 ChatGPT")
    }

    func testMissingFolderDoesNotOfferRestart() {
        let guidance = ConnectionGuidance.make(workspace: workspace, status: status, diagnostics: diagnostics(), checking: false, folderExists: false)
        XCTAssertEqual(guidance.action, .chooseFolder)
    }

    func testUnknownStatusDoesNotOfferBlindRestart() {
        let guidance = ConnectionGuidance.make(workspace: workspace, status: nil, diagnostics: nil, checking: false, folderExists: true)
        XCTAssertEqual(guidance.action, .check)
    }

    func testChangedAddressInvalidatesWizardConfirmationAndTest() {
        var progress = ConnectionSetupProgress()
        let old = "https://old.trycloudflare.com/mcp"
        progress.observe(old)
        progress.markAddressCopied(old)
        XCTAssertTrue(progress.confirmSettings(old))
        progress.markTestPromptCopied()
        XCTAssertTrue(progress.canConfirmTest)
        progress.observe("https://new.trycloudflare.com/mcp")
        XCTAssertFalse(progress.addressCopied)
        XCTAssertFalse(progress.settingsConfirmed)
        XCTAssertFalse(progress.canConfirmTest)
        XCTAssertFalse(progress.confirmSettings(old))
    }

    func testEquivalentAddressDoesNotDiscardCompletedSteps() {
        var progress = ConnectionSetupProgress()
        let url = "https://current.trycloudflare.com/mcp"
        progress.observe(url)
        progress.markAddressCopied(url)
        XCTAssertTrue(progress.confirmSettings(url))
        progress.observe("https://current.trycloudflare.com:443/mcp/")
        XCTAssertTrue(progress.settingsConfirmed)
    }

    func testCannotConfirmTestBeforeSettingsAndPrompt() {
        var progress = ConnectionSetupProgress()
        let url = "https://current.trycloudflare.com/mcp"
        progress.observe(url)
        progress.markTestPromptCopied()
        XCTAssertFalse(progress.canConfirmTest)
        XCTAssertFalse(progress.confirmSettings(url))
        progress.markAddressCopied(url)
        XCTAssertTrue(progress.confirmSettings(url))
        XCTAssertFalse(progress.canConfirmTest)
        progress.markTestPromptCopied()
        XCTAssertTrue(progress.canConfirmTest)
    }

    func testSupportReportExcludesLocalPathAndRawCLIOutput() {
        let status = WorkspaceStatus(running: nil, state: "unknown", reason: "pairingCode=SECRET-CODE bearer=SECRET-TOKEN",
                                     port: nil, pid: nil, publicUrl: nil, tunnel: nil, tokenCount: nil, pairingActive: nil)
        let report = ConnectionSupportReport.make(workspace: workspace, status: status, diagnostics: nil)
        XCTAssertFalse(report.contains(workspace.path))
        XCTAssertFalse(report.contains("SECRET"))
        XCTAssertTrue(report.contains("未確認"))
    }
}
