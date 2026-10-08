import Foundation

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

struct C2CClient {
    private let cliPath = RuntimePaths.current.cli
    private static let resolvedNodePath = findSupportedNode()

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

    func run(_ arguments: [String], entry: String? = nil) async throws -> CommandResult {
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

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminated in
                continuation.resume(returning: terminated.terminationStatus)
            }
            do { try process.run() }
            catch {
                try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
        let output = String(data: await outputTask.value, encoding: .utf8) ?? ""
        let error = String(data: await errorTask.value, encoding: .utf8) ?? ""
        return CommandResult(code: exitCode, output: output.trimmingCharacters(in: .whitespacesAndNewlines), error: error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func status(for workspace: WorkspaceRecord) async throws -> WorkspaceStatus {
        let result = try await run(["status", "--workspace", workspace.path, "--json"])
        guard result.code == 0 else { throw C2CClientError.commandFailed(result.error.isEmpty ? result.output : result.error) }
        guard let data = result.output.data(using: .utf8),
              let status = try? JSONDecoder().decode(WorkspaceStatus.self, from: data) else {
            throw C2CClientError.invalidOutput(result.output)
        }
        return status
    }

    func start(_ workspace: WorkspaceRecord) async throws -> StartResult {
        let result: CommandResult
        if workspace.provider == .tailscale {
            let backend = URL(fileURLWithPath: cliPath).deletingLastPathComponent().deletingLastPathComponent().path
            result = try await run(["start", backend, workspace.path], entry: tailscaleLauncher)
        } else {
            result = try await run(["start", "--workspace", workspace.path, "--tunnel", "--json"])
        }
        guard let data = result.output.data(using: .utf8),
              let response = try? JSONDecoder().decode(StartResult.self, from: data) else {
            throw C2CClientError.commandFailed(result.error.isEmpty ? result.output : result.error)
        }
        guard result.code == 0 && response.ok else {
            throw C2CClientError.commandFailed(response.message ?? response.error ?? result.error)
        }
        return response
    }

    func tailscaleSetup() async throws -> TailscaleSetup {
        let result = try await run(["preflight"], entry: resource("Tailscale/launcher.mjs"))
        guard result.code == 0, let data = result.output.data(using: .utf8),
              let setup = try? JSONDecoder().decode(TailscaleSetup.self, from: data) else {
            throw C2CClientError.commandFailed("未能檢查 Tailscale，請先開啟 Tailscale App。")
        }
        return setup
    }

    func gateway(_ action: String, input: Data? = nil) async throws -> Data {
        let helper = try resource("Gateway/launcher.mjs")
        let backend = URL(fileURLWithPath: cliPath).deletingLastPathComponent().deletingLastPathComponent().path
        var arguments = [action, backend]
        if let input, let json = String(data: input, encoding: .utf8) { arguments.append(json) }
        let result = try await run(arguments, entry: helper)
        guard let data = result.output.data(using: .utf8),
              let response = try? JSONDecoder().decode(GatewayCommandResponse.self, from: data) else {
            throw C2CClientError.commandFailed("共用連線未能回應。")
        }
        guard result.code == 0, response.ok else {
            throw C2CClientError.commandFailed(response.message ?? "共用連線未能完成操作。")
        }
        return data
    }

    func stop(_ workspace: WorkspaceRecord) async throws {
        let result = try await run(["stop", "--workspace", workspace.path])
        guard result.code == 0 else { throw C2CClientError.commandFailed(result.error.isEmpty ? result.output : result.error) }
    }

    func pair(_ workspace: WorkspaceRecord) async throws -> PairingCode {
        let result = try await run(["pair", "--workspace", workspace.path, "--json"])
        guard result.code == 0,
              let data = result.output.data(using: .utf8),
              let response = try? JSONDecoder().decode(PairingResult.self, from: data),
              response.ok else {
            throw C2CClientError.commandFailed(result.error.isEmpty ? result.output : result.error)
        }
        return PairingCode(value: response.pairingCode, expiresAt: Date(timeIntervalSince1970: response.expiresAt / 1000))
    }

    func unpair(_ workspace: WorkspaceRecord) async throws {
        let result = try await run(["unpair", "--workspace", workspace.path])
        guard result.code == 0 else { throw C2CClientError.commandFailed(result.error.isEmpty ? result.output : result.error) }
    }
}
