import Combine
import Foundation

struct AISetupDraft: Codable, Equatable {
    enum App: String, Codable, CaseIterable {
        case chatGPT, claude, other
        var title: String {
            switch self { case .chatGPT: return "ChatGPT"; case .claude: return "Claude"; case .other: return "Other MCP App" }
        }
    }
    enum Stage: String, Codable { case configureClient, authorize, completed }
    let id: UUID
    let gateID: String
    let app: App
    var stage: Stage
    var pairingSessionIDs: [String]
    var clientID: String?
    let createdAt: Date
    var updatedAt: Date
    var inProgress: Bool { stage != .completed }
}

/// Non-secret UI progress. Authorization remains owned by the Gate's AuthStore.
@MainActor
final class AISetupStore: ObservableObject {
    @Published private(set) var draft: AISetupDraft?
    @Published private(set) var error: String?
    @Published private(set) var completedGateIDs: Set<String> = []
    let file: URL
    private var completionFile: URL { file.deletingPathExtension().appendingPathExtension("completed.json") }
    private let now: () -> Date
    static let lifetime: TimeInterval = 7 * 86400

    init(file: URL = AppDataPaths.current.directory.appendingPathComponent("ai-setup.json"), now: @escaping () -> Date = Date.init) {
        self.file = file; self.now = now
        if FileManager.default.fileExists(atPath: file.path) {
            do { draft = try JSONDecoder().decode(AISetupDraft.self, from: Data(contentsOf: file)) }
            catch { self.error = "Saved setup couldn't be read. Please try again." }
        }
        if FileManager.default.fileExists(atPath: completionFile.path) {
            do { completedGateIDs = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: completionFile)) }
            catch { self.error = "Saved onboarding status couldn't be read." }
        }
        if let draft, draft.stage == .completed { recordCompletion(gateID: draft.gateID) }
    }

    /// Monotonic UI history, scoped to Gate identity. Clearing/revoking a draft never resets onboarding.
    func recordCompletion(gateID: String) {
        guard !completedGateIDs.contains(gateID) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var values = completedGateIDs; values.insert(gateID)
            try JSONEncoder().encode(values).write(to: completionFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: completionFile.path)
            completedGateIDs = values
        } catch { self.error = "Onboarding status couldn't be saved." }
    }

    func observeAuthorization(gateID: String?, connections: [GatewayAIConnection]?) {
        guard let gateID, connections?.contains(where: \.isAuthorized) == true else { return }
        recordCompletion(gateID: gateID)
    }

    @discardableResult
    func begin(_ app: AISetupDraft.App, gateID: String) -> Bool {
        guard draft?.inProgress != true else { return false }
        let date = now()
        return save(.init(id: UUID(), gateID: gateID, app: app, stage: .configureClient,
                          pairingSessionIDs: [], clientID: nil, createdAt: date, updatedAt: date))
    }

    func authorize() {
        guard var value = draft, value.inProgress else { return }
        value.stage = .authorize; value.updatedAt = now(); _ = save(value)
    }

    func attach(_ pairing: GatewayPairing) {
        guard var value = draft, value.inProgress, let sessionID = pairing.sessionID else { return }
        value.stage = .authorize
        if !value.pairingSessionIDs.contains(sessionID) { value.pairingSessionIDs.append(sessionID) }
        value.updatedAt = now(); _ = save(value)
    }

    func reconcile(gateID: String?, connections: [GatewayAIConnection]?, pairingActive: Bool?) {
        guard let value = draft, let gateID, let connections else { return }
        // Never transfer a setup attempt to a different Gate identity.
        guard value.gateID == gateID else { _ = clear(); return }
        let associated = connections.filter { connection in
            connection.pairingSessionID.map { value.pairingSessionIDs.contains($0) } == true
                || connection.authorizationSessionID.map { value.pairingSessionIDs.contains($0) } == true
        }
        if let authorized = associated.first(where: { $0.isAuthorized && $0.authorizationSessionID.map { value.pairingSessionIDs.contains($0) } == true }) {
            recordCompletion(gateID: gateID)
            if value.stage != .completed || value.clientID != authorized.clientID {
                var completed = value; completed.stage = .completed; completed.clientID = authorized.clientID
                completed.updatedAt = now(); _ = save(completed)
            }
        } else if value.stage == .completed {
            // A revoked/removed authorization must not remain a completed UI draft.
            _ = clear()
        } else if now().timeIntervalSince(value.updatedAt) > Self.lifetime,
                  associated.isEmpty, pairingActive == false {
            _ = clear()
        }
    }

    @discardableResult
    func clear() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            draft = nil; error = nil; return true
        } catch { self.error = "Setup couldn't be cleared. Please try again."; return false }
    }

    private func save(_ value: AISetupDraft) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(value).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            draft = value; error = nil; return true
        } catch { self.error = "Setup progress couldn't be saved. Please try again."; return false }
    }
}
