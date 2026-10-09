import Foundation

/// The lock protects registry membership only, never Process lifecycle work.
final class ActiveCommandRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func register(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        processes[ObjectIdentifier(process)] = process
    }

    func unregister(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        processes[ObjectIdentifier(process)] = nil
    }

    func snapshot() -> [Process] {
        lock.lock()
        defer { lock.unlock() }
        return Array(processes.values)
    }
}

struct CommandResult {
    let code: Int32
    let output: String
    let error: String
}

enum C2CClientError: LocalizedError {
    case missingCLI
    case missingNode
    case invalidOutput(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI: return "安裝包缺少 Runtime/C2C/bin/c2c.js，請重新安裝 Boundas Gate。"
        case .missingNode: return "安裝包缺少 Runtime/bin/node，請重新安裝 Boundas Gate。"
        case .invalidOutput(let detail): return "C2C 回傳資料無效：\(detail)"
        case .commandFailed(let detail): return detail
        }
    }
}

@MainActor
protocol SideGateClient {
    func decommission(_ workspace: WorkspaceRecord) async throws
}

@MainActor
protocol GatewayClient {
    func gateway(_ action: String, input: Data?, sourceID: String?) async throws -> Data
}

struct C2CClient: SideGateClient, GatewayClient {
    private let cliPath = RuntimePaths.current.cli
    private static let resolvedNodePath = findSupportedNode()
    private static let activeCommands = ActiveCommandRegistry()

    private static func findSupportedNode() -> String? {
        if let bundled = RuntimePaths.current.bundledNode { return bundled }
        if RuntimePaths.current.bundled { return nil }
        let nvmDirectory = NSString(string: "~/.nvm/versions/node").expandingTildeInPath
        let nvmVersions = ((try? FileManager.default.contentsOfDirectory(atPath: nvmDirectory)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvmDirectory)/\($0)/bin/node" }
        let candidates = nvmVersions + ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        return candidates.first { candidate in
            guard FileManager.default.isExecutableFile(atPath: candidate) else { return false }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: candidate)
            process.arguments = ["--version"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let version = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                  let major = Int(version.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(separator: ".").first ?? ""),
                  major >= 20 else { return false }
            return true
        }
    }

    private func resource(_ name: String) throws -> String {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try RuntimePaths.current.resource(name, developerRoot: sourceRoot).path
    }

    func run(_ arguments: [String], entry: String? = nil, timeout: TimeInterval? = nil) async throws -> CommandResult {
        if let entry, !FileManager.default.fileExists(atPath: entry) { throw RuntimeResourceError.missing(URL(fileURLWithPath: entry).lastPathComponent) }
        guard FileManager.default.fileExists(atPath: cliPath) else { throw C2CClientError.missingCLI }
        guard let nodePath = Self.resolvedNodePath else { throw C2CClientError.missingNode }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [entry ?? cliPath] + arguments
        var environment = AppDataPaths.current.childEnvironment(ProcessInfo.processInfo.environment)
        for key in ["NODE_OPTIONS", "NODE_PATH", "TS_AUTHKEY", "TS_AUTH_KEY", "TS_CLIENT_SECRET", "TSNET_FORCE_LOGIN"] {
            environment.removeValue(forKey: key)
        }
        environment["C2C_TUNNEL_PROTOCOL"] = "http2"
        if let cloudflared = RuntimePaths.current.cloudflared { environment["C2C_CLOUDFLARED_PATH"] = cloudflared }
        let nodeDirectory = URL(fileURLWithPath: nodePath).deletingLastPathComponent().path
        environment["PATH"] = "\(nodeDirectory):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Drain both streams while the child runs to avoid pipe-buffer deadlock.
        let outputTask = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        let errorTask = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }

        Self.activeCommands.register(process)
        defer { Self.activeCommands.unregister(process) }
        var timeoutWork: DispatchWorkItem?
        defer { timeoutWork?.cancel() }
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminated in
                continuation.resume(returning: terminated.terminationStatus)
            }
            do {
                try process.run()
                if let timeout {
                    let work = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                    timeoutWork = work
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
                }
            }
            catch {
                try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
        let output = String(data: await outputTask.value, encoding: .utf8) ?? ""
        let error = String(data: await errorTask.value, encoding: .utf8) ?? ""
        return CommandResult(code: exitCode, output: output.trimmingCharacters(in: .whitespacesAndNewlines), error: error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Cancel only command Process objects launched by this app/profile.
    /// Detached Gate/helper children are shut down separately with ownership checks.
    static func cancelActiveCommands() async {
        let processes = activeCommands.snapshot()
        for process in processes where process.isRunning { process.terminate() }
        if !processes.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func shutdownApplication() async -> AppShutdownReport {
        do {
            let result = try await run([], entry: resource("Gateway/app-shutdown.mjs"), timeout: 35)
            guard let data = result.output.data(using: .utf8),
                  let report = try? JSONDecoder().decode(AppShutdownReport.self, from: data) else {
                return .failed("Shutdown command did not acknowledge completion (exit \(result.code)). \(result.error.suffix(500))")
            }
            return report
        } catch { return .failed(error.localizedDescription) }
    }

    func gateway(_ action: String, input: Data? = nil, sourceID: String? = nil) async throws -> Data {
        let helper = try resource(sourceID == nil ? "Gateway/launcher.mjs" : "Gateway/side-lifecycle.mjs")
        let backend = URL(fileURLWithPath: cliPath).deletingLastPathComponent().deletingLastPathComponent().path
        var arguments = [action, backend]
        if let sourceID { arguments.append(sourceID) }
        if let input, let json = String(data: input, encoding: .utf8) { arguments.append(json) }
        let result: CommandResult
        do { result = try await run(arguments, entry: helper) }
        catch {
            GatewayDiagnosticsLog.record(.init(code: -1, output: "", error: error.localizedDescription), action: action)
            throw error
        }
        guard let data = result.output.data(using: .utf8),
              let response = try? JSONDecoder().decode(GatewayCommandResponse.self, from: data) else {
            GatewayDiagnosticsLog.record(result, action: action)
            throw C2CClientError.commandFailed("Gate 未能回應；詳細原因已記錄。")
        }
        guard result.code == 0, response.ok else {
            GatewayDiagnosticsLog.record(result, action: action)
            throw C2CClientError.commandFailed(response.message ?? "共用連線未能完成操作。")
        }
        return data
    }

    func decommission(_ workspace: WorkspaceRecord) async throws {
        let result = try await sideLifecycle("decommission", workspace)
        guard result.code == 0 else { throw C2CClientError.commandFailed(result.error.isEmpty ? result.output : result.error) }
    }

    private func sideLifecycle(_ action: String, _ workspace: WorkspaceRecord) async throws -> CommandResult {
        let helper = try resource("Gateway/side-lifecycle.mjs")
        let result: CommandResult
        do { result = try await run([action, RuntimePaths.current.backend, workspace.id.uuidString.lowercased()], entry: helper) }
        catch {
            GatewayDiagnosticsLog.record(.init(code: -1, output: "", error: error.localizedDescription), action: "side-\(action)")
            throw error
        }
        guard let data = result.output.data(using: .utf8),
              let response = try? JSONDecoder().decode(GatewayCommandResponse.self, from: data) else {
            GatewayDiagnosticsLog.record(result, action: "side-\(action)")
            throw C2CClientError.commandFailed("Side Gate 未能回應；詳細原因已記錄。")
        }
        guard result.code == 0, response.ok else {
            GatewayDiagnosticsLog.record(result, action: "side-\(action)")
            throw C2CClientError.commandFailed(response.message ?? "Side Gate 未能完成操作。")
        }
        return result
    }

}
