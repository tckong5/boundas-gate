import Foundation

struct ConnectionCheck: Equatable {
    enum State { case passed, failed, notChecked }
    let state: State
    let detail: String
    var isDNSFailure = false
    var passed: Bool { state == .passed }

    static func success(_ detail: String) -> Self { .init(state: .passed, detail: detail) }
    static func failure(_ detail: String, error: Error? = nil) -> Self {
        let cause = error as NSError?
        let dnsFailure = cause?.domain == NSURLErrorDomain
            && [URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue].contains(cause?.code ?? 0)
        return .init(state: .failed, detail: detail, isDNSFailure: dnsFailure)
    }
    static func pending(_ detail: String) -> Self { .init(state: .notChecked, detail: detail) }
}

struct ConnectionDiagnostics {
    let checkedAt: Date
    let bridge: ConnectionCheck
    let localMCP: ConnectionCheck
    let publicEndpoint: ConnectionCheck
    let publicMCP: ConnectionCheck
    let address: ConnectionCheck

    var isUsable: Bool {
        bridge.passed && localMCP.passed && publicEndpoint.passed && publicMCP.passed && address.passed
    }
    var hasPublicDNSFailure: Bool {
        bridge.passed && localMCP.passed && (publicEndpoint.isDNSFailure || publicMCP.isDNSFailure)
    }
}

enum EndpointAddress {
    static func normalized(_ raw: String?) -> String? {
        guard let raw, var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string
    }

    static func mcpURL(_ raw: String?) -> String? {
        guard let normalized = normalized(raw), let url = URL(string: normalized) else { return nil }
        if url.path.isEmpty { return normalized + "/mcp" }
        if url.path == "/mcp" || isWorkspaceBase(url.path) && url.path.hasSuffix("/mcp") { return normalized }
        return isWorkspaceBase(url.path) ? normalized + "/mcp" : nil
    }

    private static func isWorkspaceBase(_ path: String) -> Bool {
        path.range(of: #"^/c2c/[a-f0-9]{12}(/mcp)?$"#, options: .regularExpression) != nil
    }

    static func publicBase(_ raw: String?) -> URL? {
        guard let normalized = normalized(raw), var parts = URLComponents(string: normalized),
              parts.scheme == "https", parts.path.isEmpty || parts.path == "/mcp" || isWorkspaceBase(parts.path) else { return nil }
        if parts.path.hasSuffix("/mcp") { parts.path = String(parts.path.dropLast(4)) }
        return parts.url
    }
}

struct ConnectionChecker {
    private struct Health: Decodable {
        let service: String
        let workspaceId: String
        let status: String
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 6
            config.timeoutIntervalForResource = 8
            self.session = URLSession(configuration: config)
        }
    }

    func check(workspaceID: String, status: WorkspaceStatus, service: String = "c2c-bridge") async -> ConnectionDiagnostics {
        guard status.running == true, let port = status.port, (1...65535).contains(port) else {
            let detail = status.running == false ? "Bridge 未運行" : "Bridge 狀態未能確認"
            let pending = ConnectionCheck.pending(detail)
            return .init(checkedAt: Date(), bridge: pending, localMCP: pending,
                         publicEndpoint: .pending("未能檢查公開 URL"), publicMCP: pending,
                         address: .pending("未能確認 URL"))
        }

        let local = URL(string: "http://127.0.0.1:\(port)")!
        let publicBase = EndpointAddress.publicBase(status.publicUrl ?? status.tunnel?.url)
        async let localHealth = health(at: local, workspaceID: workspaceID, service: service)
        async let remoteHealth: ConnectionCheck = publicBase != nil
            ? health(at: publicBase!, workspaceID: workspaceID, service: service)
            : .pending("未啟用公開連線")
        let (bridge, publicEndpoint) = await (localHealth, remoteHealth)
        async let localAuth: ConnectionCheck = bridge.passed
            ? authentication(at: local, expectedPublicBase: publicBase)
            : .pending("先修復本機 Bridge")
        async let remoteAuth: ConnectionCheck = publicEndpoint.passed && publicBase != nil
            ? authentication(at: publicBase!, expectedPublicBase: publicBase)
            : .pending("先修復公開連線")
        let (localMCP, publicMCP) = await (localAuth, remoteAuth)

        let address: ConnectionCheck
        if let published = EndpointAddress.normalized(status.publicUrl),
           let tunnel = EndpointAddress.normalized(status.tunnel?.url) {
            address = published == tunnel
                ? .success("Bridge 公布嘅 URL 同 Tunnel 一致")
                : .failure("Bridge 公布嘅 URL 同 Tunnel 唔一致，需要重建連線")
        } else {
            address = publicBase == nil ? .pending("未啟用公開連線") : .failure("Bridge／Tunnel URL 資料不完整")
        }
        return .init(checkedAt: Date(), bridge: bridge, localMCP: localMCP,
                     publicEndpoint: publicEndpoint, publicMCP: publicMCP, address: address)
    }

    private func health(at base: URL, workspaceID: String, service: String) async -> ConnectionCheck {
        do {
            let (data, response) = try await session.data(for: request(base.appendingPathComponent("health")))
            guard let http = response as? HTTPURLResponse else { return .failure("回應格式無效") }
            guard http.statusCode == 200 else { return .failure("端點未能連通（HTTP \(http.statusCode)）") }
            guard let body = try? JSONDecoder().decode(Health.self, from: data),
                  body.service == service, body.status == "ok" else {
                return .failure("回應唔係正常嘅 C2C Bridge")
            }
            guard body.workspaceId == workspaceID else { return .failure("端點連到另一個 workspace") }
            return .success("可連通，workspace ID 已核對")
        } catch {
            return .failure("未能連通：\(error.localizedDescription)", error: error)
        }
    }

    private func authentication(at base: URL, expectedPublicBase: URL?) async -> ConnectionCheck {
        do {
            var probe = request(base.appendingPathComponent("mcp"))
            probe.httpMethod = "POST"
            probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
            probe.httpBody = Data(#"{"jsonrpc":"2.0","method":"ping","id":1}"#.utf8)
            let (_, response) = try await session.data(for: probe)
            guard let http = response as? HTTPURLResponse else { return .failure("回應格式無效") }
            guard http.statusCode == 401 else {
                return .failure("未授權請求應回 401，實際回 \(http.statusCode)")
            }
            guard let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate"),
                  let metadata = Self.metadataURL(in: challenge) else {
                return .failure("401 回應缺少 OAuth discovery URL")
            }
            if let expectedPublicBase {
                let expected = expectedPublicBase.appendingPathComponent(".well-known/oauth-protected-resource/mcp")
                guard EndpointAddress.normalized(metadata) == EndpointAddress.normalized(expected.absoluteString) else {
                    return .failure("OAuth discovery 指向另一個 URL，需要重建連線")
                }
            }
            return .success("401 正常，OAuth discovery URL 已核對")
        } catch {
            return .failure("MCP 未能連通：\(error.localizedDescription)", error: error)
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func metadataURL(in challenge: String) -> String? {
        guard challenge.lowercased().hasPrefix("bearer"),
              let regex = try? NSRegularExpression(pattern: #"resource_metadata\s*=\s*"([^"]+)""#, options: .caseInsensitive),
              let match = regex.firstMatch(in: challenge, range: NSRange(challenge.startIndex..., in: challenge)),
              let range = Range(match.range(at: 1), in: challenge) else { return nil }
        return String(challenge[range])
    }
}
