import XCTest
@testable import C2CManager

@MainActor
final class AppQuitCoordinatorTests: XCTestCase {
    func testClosingWindowDoesNotRequestShutdownOrMutateGateIntent() async {
        var shutdownCalls = 0
        let desiredRunning = ["Main": true, "Side": true]
        let coordinator = AppQuitCoordinator(freeze: { XCTFail("Closing window must not freeze") }, shutdown: {
            shutdownCalls += 1
            return .init(ok: true, failures: [])
        }, record: { _ in XCTFail("No shutdown") }, finish: { XCTFail("No termination") })
        XCTAssertFalse(AppWindowLifecycle.terminateAfterLastWindowClosed)
        XCTAssertFalse(coordinator.quitting)
        XCTAssertEqual(shutdownCalls, 0)
        XCTAssertEqual(desiredRunning, ["Main": true, "Side": true])
    }
    func testShowRestoresSingleManagerSceneAndFocusesIt() {
        let originalSession = NSObject()
        var sessions = ["manager": originalSession], restored: [String] = [], focus = 0
        for _ in 0..<2 {
            AppWindowLifecycle.show(restore: { id in
                restored.append(id)
                XCTAssertTrue(sessions[id] === originalSession)
            }, activate: { focus += 1 })
        }
        XCTAssertEqual(restored, ["manager", "manager"])
        XCTAssertEqual(focus, 2)
        XCTAssertEqual(sessions.count, 1)
        sessions.removeAll()
    }
    func testExplicitQuitFreezesThenWaitsForShutdownBeforeTerminatingExactlyOnce() async {
        var events: [String] = []
        let finished = expectation(description: "Quit finished")
        var acknowledgement: CheckedContinuation<AppShutdownReport, Never>?
        let coordinator = AppQuitCoordinator(freeze: { events.append("freeze") }, shutdown: {
            events.append("shutdown")
            return await withCheckedContinuation { acknowledgement = $0 }
        }, record: { report in XCTAssertTrue(report.ok); events.append("record") }, finish: {
            events.append("terminate"); finished.fulfill()
        })
        coordinator.requestQuit(); coordinator.requestQuit()
        while acknowledgement == nil { await Task.yield() }
        XCTAssertEqual(events, ["freeze", "shutdown"])
        acknowledgement?.resume(returning: .init(ok: true, failures: []))
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(events, ["freeze", "shutdown", "record", "terminate"])
    }
    func testTimeoutLogsAndTerminatesUIWithoutUnverifiedKillOrSecondFinish() async {
        let finished = expectation(description: "Bounded fallback")
        var acknowledgement: CheckedContinuation<AppShutdownReport, Never>?
        var reports: [AppShutdownReport] = [], finishes = 0
        let coordinator = AppQuitCoordinator(timeout: .milliseconds(20), freeze: {}, shutdown: {
            await withCheckedContinuation { acknowledgement = $0 }
        }, record: { reports.append($0) }, finish: { finishes += 1; finished.fulfill() })
        coordinator.requestQuit()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(finishes, 1)
        XCTAssertFalse(reports[0].ok)
        XCTAssertTrue(reports[0].failures[0].message.contains("timed out"))
        acknowledgement?.resume(returning: .init(ok: true, failures: []))
        await Task.yield()
        XCTAssertEqual(finishes, 1)
    }
    func testFreezePreventsMainAndSideRecoveryWithoutWritingFolderState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = LifecycleClient()
        let main = SharedGatewayStore(automaticallyRefresh: false, client: client, connectionCheck: { _, _, _ in
            let pending = ConnectionCheck.pending("fixture")
            return .init(checkedAt: .now, bridge: pending, localMCP: pending, publicEndpoint: pending, publicMCP: pending, address: pending)
        }, diagnosticsLogFile: directory.appendingPathComponent("log"))
        let store = try WorkspaceStore(configURL: directory.appendingPathComponent("workspaces.json"), client: client, gateway: main,
            automaticallyRefresh: false, sideGatewayFactory: { workspace in
                SharedGatewayStore(automaticallyRefresh: false, gateSourceID: workspace.id.uuidString.lowercased(), client: client)
            })
        let folder = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(store.addPath(folder.path))
        store.addToSideGates(store.workspaces[0])
        let side = store.sideGateway(for: store.workspaces[0])
        let bytes = try Data(contentsOf: directory.appendingPathComponent("workspaces.json"))
        store.suspendForAppQuit()
        let mainStarted = await main.perform("start-local")
        let sideStarted = await side.perform("start-local")
        XCTAssertFalse(mainStarted); XCTAssertFalse(sideStarted)
        await store.startAll(); await store.refreshAll(); await main.recoverIfNeeded(); await side.recoverIfNeeded()
        XCTAssertEqual(client.calls.count, 0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("workspaces.json")), bytes)
    }
}
