import XCTest
@testable import C2CManager

final class ActiveCommandRegistryTests: XCTestCase {
    func testConcurrentRegisterUnregister() {
        let registry = ActiveCommandRegistry()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let process = Process()
            registry.register(process)
            XCTAssertTrue(registry.snapshot().contains { $0 === process })
            registry.unregister(process)
        }
        XCTAssertTrue(registry.snapshot().isEmpty)
    }

    func testSnapshotRemainsSafeAfterConcurrentUnregister() {
        let registry = ActiveCommandRegistry()
        let processes = (0..<50).map { _ in Process() }
        processes.forEach { registry.register($0) }
        let snapshot = registry.snapshot()
        DispatchQueue.concurrentPerform(iterations: processes.count) { index in
            registry.unregister(processes[index])
        }
        XCTAssertTrue(registry.snapshot().isEmpty)
        XCTAssertEqual(Set(snapshot.map(ObjectIdentifier.init)), Set(processes.map(ObjectIdentifier.init)))
    }

    func testSnapshotConsumerCanWaitWithoutBlockingRegistry() {
        let registry = ActiveCommandRegistry()
        let process = Process()
        registry.register(process)
        let consumerStarted = DispatchSemaphore(value: 0)
        let releaseConsumer = DispatchSemaphore(value: 0)
        let consumerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let snapshot = registry.snapshot()
            consumerStarted.signal()
            // Simulates cancellation/waiting work, without starting any process.
            _ = releaseConsumer.wait(timeout: .now() + 2)
            XCTAssertTrue(snapshot.first === process)
            consumerFinished.signal()
        }
        defer { releaseConsumer.signal() }
        XCTAssertEqual(consumerStarted.wait(timeout: .now() + 1), .success)
        let membershipFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            registry.unregister(process)
            let next = Process()
            registry.register(next)
            XCTAssertEqual(registry.snapshot().count, 1)
            registry.unregister(next)
            membershipFinished.signal()
        }
        XCTAssertEqual(membershipFinished.wait(timeout: .now() + 1), .success)
        releaseConsumer.signal()
        XCTAssertEqual(consumerFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(registry.snapshot().isEmpty)
    }
}
