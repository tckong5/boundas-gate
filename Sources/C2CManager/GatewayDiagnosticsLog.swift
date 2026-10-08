import Foundation

enum GatewayDiagnosticsLog {
    static func connectionSummary(_ diagnostics: ConnectionDiagnostics) -> String {
        let checks = [("local-service", diagnostics.bridge), ("local-mcp", diagnostics.localMCP),
                      ("public-https", diagnostics.publicEndpoint), ("public-mcp", diagnostics.publicMCP),
                      ("endpoint-match", diagnostics.address)]
        return checks.map { name, check in
            "\(name)=\(check.state) dnsFailure=\(check.isDNSFailure) \(redacted(check.detail))"
        }.joined(separator: "\n")
    }

    static func redacted(_ text: String) -> String {
        var value = String(text.prefix(16_384))
        let patterns = [
            #"(?i)(bearer\s+)\S+"#,
            #"(?i)((?:access[_-]?token|refresh[_-]?token|client[_-]?secret|admin[_-]?token|token|pairing[_-]?code|access[_-]?key|api[_-]?key|passcode|password|authorization|TS_AUTHKEY)[\"']?\s*[=:]\s*[\"']?)[^\s,\"'}]+"#,
            #"(?i)([?&](?:code|token|key|secret|state|access_token|refresh_token|access_key)=)[^&\s]+"#,
            #"(?i)\bBG-(?:[A-F0-9]{4}-){5}[A-F0-9]{4}\b"#,
            #"\b[A-Z2-9]{4}-[A-Z2-9]{4}\b"#,
            #"\b[A-Z2-9]{8}\b"#,
            #"https?://[^/@\s]+@"#,
            #"[A-Za-z0-9_+/-]{24,}={0,2}"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return value
    }

    static func record(_ result: CommandResult, action: String, file: URL = AppDataPaths.current.directory.appendingPathComponent("diagnostics/gateway-command.log")) {
        // Do not log stdout: it can contain fresh pairing/passcodes or file data.
        let text = "\(ISO8601DateFormatter().string(from: Date())) action=\(action) exit=\(result.code)\n\(redacted(result.error))\n"
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
        } catch { /* Logging must never prevent the original error reaching UI. */ }
    }
}
