import XCTest
@testable import C2CManager

final class DNSCacheRepairTests: XCTestCase {
    func testOnlyExplicitSuccessIsAccepted() {
        XCTAssertEqual(DNSCacheRepair.result(exitCode: 0, output: "refreshed\n"), .refreshed)
        XCTAssertEqual(DNSCacheRepair.result(exitCode: 1, output: "refreshed"), .failed)
        XCTAssertEqual(DNSCacheRepair.result(exitCode: 0, output: ""), .failed)
        XCTAssertEqual(DNSCacheRepair.result(exitCode: 0, output: "unexpected response"), .failed)
        XCTAssertEqual(DNSCacheRepair.result(exitCode: 0, output: "cancelled\n"), .cancelled)
    }

    @MainActor
    func testCancelledRepairCanBeRetriedWithoutInvokingSystemAuthorization() async {
        let cancelled = await DNSCacheRepair.run { .cancelled }
        XCTAssertEqual(cancelled, .cancelled)
        let retried = await DNSCacheRepair.run { .refreshed }
        XCTAssertEqual(retried, .refreshed)
    }

    @MainActor
    func testOverlappingGateRepairsDoNotOpenTwoAuthorizationPrompts() async {
        let started = AsyncStream<Void>.makeStream()
        let finish = AsyncStream<Void>.makeStream()
        let first = Task {
            await DNSCacheRepair.run {
                started.continuation.yield(())
                var iterator = finish.stream.makeAsyncIterator()
                _ = await iterator.next()
                return .refreshed
            }
        }
        // Wait for the first repair to start; no system command is run.
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let overlapping = await DNSCacheRepair.run { .failed }
        XCTAssertEqual(overlapping, .busy)
        finish.continuation.yield(())
        let completed = await first.value
        XCTAssertEqual(completed, .refreshed)
        started.continuation.finish()
        finish.continuation.finish()
    }
}
