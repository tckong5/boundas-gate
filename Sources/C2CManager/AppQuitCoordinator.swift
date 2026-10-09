import Foundation

struct AppShutdownReport: Decodable, Equatable {
    struct Failure: Decodable, Equatable { let component: String; let message: String }
    let ok: Bool
    let failures: [Failure]
    static func failed(_ message: String) -> Self {
        .init(ok: false, failures: [.init(component: "App shutdown", message: message)])
    }
}

/// Window visibility is independent of runtime ownership. The single `manager`
/// Window scene restores the same session/store, rather than a WindowGroup.
@MainActor
enum AppWindowLifecycle {
    static let terminateAfterLastWindowClosed = false
    static func show(restore: (String) -> Void, activate: () -> Void) {
        restore("manager")
        activate()
    }
}

@MainActor
final class AppQuitCoordinator {
    private(set) var quitting = false
    private let freeze: () -> Void
    private let shutdown: () async -> AppShutdownReport
    private let record: (AppShutdownReport) -> Void
    private let finish: () -> Void
    private let timeout: Duration

    init(timeout: Duration = .seconds(40), freeze: @escaping () -> Void,
         shutdown: @escaping () async -> AppShutdownReport,
         record: @escaping (AppShutdownReport) -> Void, finish: @escaping () -> Void) {
        self.timeout = timeout; self.freeze = freeze; self.shutdown = shutdown
        self.record = record; self.finish = finish
    }

    func requestQuit() {
        guard !quitting else { return }
        quitting = true
        freeze()
        Task {
            let report = await boundedShutdown()
            record(report)
            // Unknown/failed components are logged, never killed by name.
            // The bounded safe fallback is to exit the UI, preserving intent.
            finish()
        }
    }

    private func boundedShutdown() async -> AppShutdownReport {
        await withCheckedContinuation { continuation in
            var completed = false
            let work = Task { await shutdown() }
            Task {
                let report = await work.value
                guard !completed else { return }
                completed = true
                continuation.resume(returning: report)
            }
            Task {
                try? await Task.sleep(for: timeout)
                guard !completed else { return }
                completed = true
                work.cancel()
                continuation.resume(returning: .failed("Shutdown timed out. Unverified processes were left untouched."))
            }
        }
    }
}
