import Darwin
import Foundation

struct GateActivityRequest: Decodable, Equatable, Identifiable {
    let requestID: String
    let gateID: String
    let clientID: String
    let workspaceID: String?
    let tool: String
    let startedAt: Double
    var id: String { requestID }
}

struct GateActivityEvent: Decodable, Equatable {
    let requestID: String
    let gateID: String
    let clientID: String
    let workspaceID: String?
    let tool: String
    let startedAt: Double
    let timestamp: Double
    let type: String
    let sequence: Int
    let success: Bool?
    let duration: Double?
    var request: GateActivityRequest {
        .init(requestID: requestID, gateID: gateID, clientID: clientID, workspaceID: workspaceID,
              tool: tool, startedAt: startedAt)
    }
}

struct GateActivityPage: Decodable {
    struct Folder: Decodable { let workspaceID: String; let available: Bool }
    let version: Int
    let gateID: String
    let streamID: String
    let cursor: Int
    let reset: Bool
    let events: [GateActivityEvent]
    let activeRequests: [GateActivityRequest]
    let folders: [Folder]
}

protocol GateActivityFetching {
    func fetch(gateID: String, since: Int?) async throws -> GateActivityPage
}

enum GateActivityError: Error { case unavailable, identityChanged, invalidRuntime }

private final class LocalActivitySessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Main Gate only. The private runtime is verified before sending the local admin credential.
final class GateActivityClient: GateActivityFetching {
    struct Runtime: Decodable {
        let service: String; let workspaceId: String; let port: Int
        let instanceID: String; let adminToken: String
        func matches(gateID: String) -> Bool {
            service == "boundas-gateway" && workspaceId == gateID && (1...65535).contains(port)
                && instanceID.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                && adminToken.range(of: "^bg_admin_[a-f0-9]{64}$", options: .regularExpression) != nil
        }
    }
    struct Health: Decodable { let service: String; let workspaceId: String; let instanceID: String; let status: String }
    private let runtimeFile: URL
    private let session: URLSession
    init(runtimeFile: URL = AppDataPaths.current.gateway.appendingPathComponent("runtime.json")) {
        self.runtimeFile = runtimeFile
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 4
        session = URLSession(configuration: config, delegate: LocalActivitySessionDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    private func runtime(gateID: String) throws -> Runtime {
        let fd = open(runtimeFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GateActivityError.invalidRuntime }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var statInfo = stat()
        guard fstat(fd, &statInfo) == 0, statInfo.st_uid == getuid(),
              statInfo.st_mode & S_IFMT == S_IFREG, statInfo.st_mode & 0o077 == 0,
              statInfo.st_size > 0, statInfo.st_size < 16384 else { throw GateActivityError.invalidRuntime }
        let value = try JSONDecoder().decode(Runtime.self, from: handle.readToEnd() ?? Data())
        guard value.matches(gateID: gateID) else { throw GateActivityError.invalidRuntime }
        return value
    }

    func fetch(gateID: String, since: Int?) async throws -> GateActivityPage {
        let value = try runtime(gateID: gateID)
        let base = "http://127.0.0.1:\(value.port)"
        let (healthData, response) = try await session.data(from: URL(string: base + "/health")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GateActivityError.unavailable }
        let health = try JSONDecoder().decode(Health.self, from: healthData)
        guard health.service == value.service, health.workspaceId == gateID,
              health.instanceID == value.instanceID, health.status == "ok" else { throw GateActivityError.identityChanged }
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: base + "/control/activity" + (since.map { "?since=\($0)" } ?? ""))!)
        request.setValue("Bearer \(value.adminToken)", forHTTPHeaderField: "Authorization")
        request.setValue(value.instanceID, forHTTPHeaderField: "X-Boundas-Gate-Instance")
        let (data, result) = try await session.data(for: request)
        guard (result as? HTTPURLResponse)?.statusCode == 200, data.count < 1_048_576 else { throw GateActivityError.unavailable }
        let page = try JSONDecoder().decode(GateActivityPage.self, from: data)
        guard page.version == 1, page.gateID == gateID, page.cursor >= 0,
              page.events.count <= 512, page.activeRequests.count <= 256 else { throw GateActivityError.identityChanged }
        return page
    }
}
