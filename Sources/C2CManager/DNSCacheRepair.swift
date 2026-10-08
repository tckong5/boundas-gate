import Foundation

/// A user-requested system cache refresh, never a background recovery action.
@MainActor
enum DNSCacheRepair {
    enum Result: Equatable { case refreshed, cancelled, failed, busy }
    private static var running = false

    // No Gate URL, Folder path, credentials or caller-supplied command enters
    // this privileged script. macOS owns the administrator password prompt.
    nonisolated static let script = """
    try
        do shell script "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder" with prompt "Boundas Gate needs to refresh this Mac's DNS cache to repair secure access." with administrator privileges
        return "refreshed"
    on error number errorNumber
        if errorNumber is -128 then return "cancelled"
        return "failed"
    end try
    """

    static func run(execute: @escaping @Sendable () async -> Result = { await executeSystemRepair() }) async -> Result {
        guard !running else { return .busy }
        running = true
        defer { running = false }
        return await execute()
    }

    nonisolated static func result(exitCode: Int32, output: String) -> Result {
        guard exitCode == 0 else { return .failed }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "refreshed": return .refreshed
        case "cancelled": return .cancelled
        default: return .failed
        }
    }

    nonisolated private static func executeSystemRepair() async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: result(exitCode: process.terminationStatus,
                        output: String(data: data, encoding: .utf8) ?? ""))
                } catch { continuation.resume(returning: .failed) }
            }
        }
    }
}
