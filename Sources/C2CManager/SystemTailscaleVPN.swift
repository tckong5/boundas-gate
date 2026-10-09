import Foundation

/// macOS system VPN evidence/recovery only; never owns tsnet or Gate state.
struct SystemTailscaleVPN {
    static let provider = "io.tailscale.ipn.macsys"
    struct Service: Equatable {
        let id: String
        let provider: String
        let connected: Bool
    }
    struct Interception: Equatable {
        let hostname: String
        let service: Service
    }
    struct CommandResult { let code: Int32; let output: String }
    enum RecoveryError: Error, LocalizedError, Equatable {
        case confirmationRequired, serviceChanged, commandFailed, stillConnected
        var errorDescription: String? {
            switch self {
            case .confirmationRequired: return "Confirm before disconnecting the old Tailscale VPN."
            case .serviceChanged: return "The system Tailscale connection changed. Recheck this Gate before trying again."
            case .commandFailed: return "Couldn't disconnect the old Tailscale VPN. Your VPN configuration and Gate identity are unchanged."
            case .stillConnected: return "The old Tailscale VPN is still connected. Open Network Settings, then recheck."
            }
        }
    }
    var command: (String, [String]) async throws -> CommandResult = Self.execute
    var settle: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }

    static func services(in text: String) -> [Service] {
        let pattern = #"^\s*\*?\s*\((Connected|Disconnected)\)\s+([A-Fa-f0-9-]{36})\s+VPN\s+\(([^)]+)\)"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            func field(_ index: Int) -> String { String(text[Range(match.range(at: index), in: text)!]) }
            guard UUID(uuidString: field(2)) != nil else { return nil }
            return Service(id: field(2), provider: field(3), connected: field(1) == "Connected")
        }
    }
    static func isTailnetAddress(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 && bytes[0] == 100 && (64...127).contains(bytes[1])
    }
    static func classify(hostname: String, transportFailure: Bool, services: [Service], addresses: [String]) -> Interception? {
        guard transportFailure, hostname.range(of: #"^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$"#, options: .regularExpression) != nil,
              addresses.contains(where: isTailnetAddress),
              let service = services.first(where: { $0.provider == provider && $0.connected }) else { return nil }
        return .init(hostname: hostname, service: service)
    }
    func detectPendingMigration(_ status: GatewayStatus) async -> Interception? {
        guard status.endpointMigrationPending == true,
              status.endpointMigrationFailureDetail?.isTransportReadinessFailure == true,
              let raw = status.endpointMigrationCandidateURL, let url = URL(string: raw),
              url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil, url.path == "/mcp",
              let host = url.host else { return nil }
        return await detect(hostname: host, transportFailure: true)
    }
    func detect(hostname: String, transportFailure: Bool) async -> Interception? {
        guard transportFailure, hostname.range(of: #"^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$"#, options: .regularExpression) != nil else { return nil }
        do {
            let list = try await command("/usr/sbin/scutil", ["--nc", "list"])
            guard list.code == 0, Self.services(in: list.output).contains(where: { $0.provider == Self.provider && $0.connected }) else { return nil }
            let lookup = try await command("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", hostname])
            guard lookup.code == 0 else { return nil }
            let addresses = lookup.output.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("ip_address:") else { return nil }
                return String(line.dropFirst("ip_address:".count)).trimmingCharacters(in: .whitespaces)
            }
            return Self.classify(hostname: hostname, transportFailure: transportFailure, services: Self.services(in: list.output), addresses: addresses)
        } catch { return nil }
    }
    func disconnect(_ evidence: Interception, confirmed: Bool, recheck: () async -> Void) async throws {
        guard confirmed else { throw RecoveryError.confirmationRequired }
        let list = try await command("/usr/sbin/scutil", ["--nc", "list"])
        guard list.code == 0, evidence.service.provider == Self.provider,
              Self.services(in: list.output).contains(where: { $0.id == evidence.service.id && $0.provider == Self.provider && $0.connected }) else {
            throw RecoveryError.serviceChanged
        }
        let stopped = try await command("/usr/sbin/scutil", ["--nc", "stop", evidence.service.id])
        guard stopped.code == 0 else { throw RecoveryError.commandFailed }
        try await settle()
        let after = try await command("/usr/sbin/scutil", ["--nc", "list"])
        guard after.code == 0,
              let service = Self.services(in: after.output).first(where: { $0.id == evidence.service.id && $0.provider == Self.provider }) else { throw RecoveryError.serviceChanged }
        guard !service.connected else { throw RecoveryError.stillConnected }
        await recheck()
    }
    private static func execute(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeout.cancel()
                    continuation.resume(returning: .init(code: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? ""))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
