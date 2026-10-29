import Foundation

struct WorkspaceRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var c2cID: String
    /// Stable filesystem reference used to follow a renamed or moved Folder.
    /// Older records legitimately omit this value.
    var folderBookmark: Data?
    /// POSIX device/inode identity used by the Gateway as a substitution guard.
    /// Older records legitimately omit this value.
    var folderFileIdentity: String?
    /// Written only after bookmark-backed remount verification. Allows the
    /// Gateway to replace its cached POSIX hint without resetting policy.
    var folderIdentityRecovery: FolderIdentityRecovery?
    var lastObservedMCPURL: String?
    var previousMCPURL: String?
    var configuredMCPURL: String?
    var connectionProvider: ConnectionProvider?
    var mainGateAdded: Bool?
    var sideGateAdded: Bool?
    var mainGateOrder: Int?
    var sideGateOrder: Int?
    var sideGateRemovalState: SideGateRemovalState?
    var sideGateRemovalError: String?
    var lastKnownMCPURL: String?

    var provider: ConnectionProvider { connectionProvider ?? .cloudflare }
    var needsFolderLocation: Bool {
        guard let expected = folderFileIdentity else { return !FileManager.default.fileExists(atPath: path) }
        guard let current = WorkspaceStore.fileIdentity(path) else { return true }
        return expected != current
    }
    // Existing records retain their previous Main Gate membership.
    var belongsToMainGate: Bool { mainGateAdded != false }
    var belongsToSideGates: Bool {
        sideGateAdded == true
    }
    var canOperateSideGate: Bool { belongsToSideGates && sideGateRemovalState == nil }

    init(name: String, path: String, c2cID: String) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.c2cID = c2cID
        self.folderBookmark = nil
        self.folderFileIdentity = nil
        self.sideGateAdded = false
    }

    mutating func observeMCPURL(_ url: String) {
        guard let normalized = EndpointAddress.mcpURL(url), normalized != lastObservedMCPURL else { return }
        previousMCPURL = lastObservedMCPURL
        lastObservedMCPURL = normalized
    }

    enum ConnectorState { case unconfirmed, matches, needsUpdate }

    func connectorState(currentURL: String?) -> ConnectorState {
        guard let current = EndpointAddress.mcpURL(currentURL),
              let configured = EndpointAddress.mcpURL(configuredMCPURL) else { return .unconfirmed }
        return current == configured ? .matches : .needsUpdate
    }
}

struct FolderIdentityRecovery: Codable, Hashable {
    let previous: String
    let current: String
    let path: String
}

enum SideGateRemovalState: String, Codable { case removing, failed }

enum ConnectionProvider: String, Codable {
    case cloudflare
    case tailscale
}

struct WorkspaceStatus: Decodable {
    struct Tunnel: Decodable {
        let running: Bool
        let url: String?
    }

    let running: Bool?
    let state: String?
    let reason: String?
    let port: Int?
    let pid: Int?
    let publicUrl: String?
    let tunnel: Tunnel?
    let tokenCount: Int?
    let pairingActive: Bool?

    var mcpURL: String? {
        guard tunnel?.running == true, let url = publicUrl ?? tunnel?.url else { return nil }
        return url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/mcp"
    }
}

enum WorkspaceOperation: String {
    case move = "Moving…"
    case remove = "Removing…"
    case start = "啟動中"
    case stop = "停止中"
}
