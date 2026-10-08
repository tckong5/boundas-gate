import AppKit
import Combine
import Foundation

struct GatewayCommandResponse: Decodable {
    let ok: Bool
    let message: String?
}

struct EmbeddedConnectionSetup: Decodable {
    let state: String
    let message: String
    let loginURL: String?
    let approvalURL: String?
    let hostname: String?
    let userspace: Bool?
    var actionURL: URL? {
        guard let text = loginURL ?? approvalURL, let url = URL(string: text),
              url.scheme == "https", url.host == "login.tailscale.com", url.user == nil else { return nil }
        return url
    }
}

struct GatewayRoot: Codable, Identifiable, Equatable {
    let id: String
    let sourceID: String
    let name: String
    let path: String
    let enabled: Bool
    let epoch: String
    let codeRequired: Bool?
    let codeEpoch: String?
}

struct GatewayFolderAccess: Decodable {
    let workspaceID: String
    let codeActive: Bool
    let unlockedCount: Int
}

struct GatewayFolderCode: Decodable {
    let workspaceID: String
    let name: String
    let code: String
    let expiresAt: Double
    var expiration: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
    var unlockPrompt: String {
        "請用 Boundas Gate call unlock_workspace，Folder 通行碼係 \(code)。之後只讀取解鎖嘅 Folder，唔好顯示通行碼或 access_key。"
    }
}

struct GatewayAIConnection: Decodable, Identifiable, Equatable {
    var pairingSessionID: String? = nil
    var authorizationSessionID: String? = nil
    let clientID: String
    let name: String
    let authorizationState: String
    let authorizationExpiresAt: Double?
    let reason: String?
    var id: String { clientID }
    var isAuthorized: Bool {
        authorizationState == "authorized" && authorizationExpiresAt.map {
            $0.isFinite && Date(timeIntervalSince1970: $0 / 1000) > Date()
        } == true
    }
    var statusLabel: String {
        if isAuthorized { return "Authorized" }
        switch authorizationState {
        case "revoked": return "Revoked"
        case "invalid", "authorized": return "Invalid"
        default: return "Not authorized"
        }
    }
    var needsAttention: Bool { !isAuthorized && ["authorized", "invalid", "revoked"].contains(authorizationState) }
}

struct GatewayStatus: Decodable {
    var setupManagementVersion: Int? = nil
    var clientManagementVersion: Int? = nil
    var clientRevocationVersion: Int? = nil
    var sharedTunnel: Bool? = nil
    var sharedMigrationAvailable: Bool? = nil
    var endpointMigrationPending: Bool? = nil
    let running: Bool?
    let state: String
    let reason: String?
    let gatewayID: String?
    let port: Int?
    let pid: Int?
    let publicUrl: String?
    let tunnel: WorkspaceStatus.Tunnel?
    let tokenCount: Int?
    let pairingActive: Bool?
    let roots: [GatewayRoot]
    let configuredMCPURL: String?
    let accessCodeVersion: Int?
    let folderAccess: [GatewayFolderAccess]?
    var stableMCPURL: String? = nil
    var desiredRunning: Bool? = nil
    var localOnly: Bool? = nil
    var reconnectEnabled: Bool? = nil
    var connectionVersion: Int? = nil
    var connectionRemembered: Bool? = nil
    var authorizationVersion: Int? = nil
    var transport: String? = nil
    var transportSetup: EmbeddedConnectionSetup? = nil
    var aiConnections: [GatewayAIConnection]? = nil

    var bridgeStatus: WorkspaceStatus {
        .init(running: running, state: state, reason: reason, port: port, pid: pid, publicUrl: publicUrl,
              tunnel: tunnel, tokenCount: tokenCount, pairingActive: pairingActive)
    }
    var mcpURL: String? { bridgeStatus.mcpURL }
    var addressConfirmed: Bool {
        guard let current = EndpointAddress.mcpURL(mcpURL) else { return false }
        return EndpointAddress.mcpURL(configuredMCPURL) == current
    }
}

struct GatewayPairing: Decodable {
    var sessionID: String? = nil
    struct Root: Decodable { let id: String; let name: String }
    let pairingCode: String
    let expiresAt: Double
    let roots: [Root]
    var expiration: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
}

enum GatewayConnectionState: Equatable {
    case checking, unknown, stopped, needsRepair, ready

    static func make(status: GatewayStatus?, diagnostics: ConnectionDiagnostics?, checking: Bool) -> Self {
        guard let status, status.state != "unknown", let running = status.running else {
            return checking ? .checking : .unknown
        }
        guard running else { return .stopped }
        if status.tunnel?.running == true && diagnostics?.isUsable == true { return .ready }
        return checking ? .checking : .needsRepair
    }

    var title: String {
        switch self {
        case .checking: return "檢查中…"
        case .unknown: return "未能確認狀態"
        case .stopped: return "Gate Closed"
        case .needsRepair: return "Gate Needs Attention"
        case .ready: return "Gate Open"
        }
    }

    var button: String {
        switch self {
        case .checking, .unknown: return "重新檢查"
        case .stopped: return "Open Main Gate"
        case .needsRepair: return "Repair Main Gate"
        case .ready: return "複製 URL · 開啟 ChatGPT"
        }
    }
}

@MainActor
final class SharedGatewayStore: ObservableObject {
    static let selectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    @Published private(set) var status: GatewayStatus?
    @Published private(set) var diagnostics: ConnectionDiagnostics?
    @Published private(set) var pairing: GatewayPairing?
    @Published private(set) var folderCodes: [String: GatewayFolderCode] = [:]
    @Published private(set) var working = false
    @Published private(set) var operation: String?
    @Published private(set) var restarting = false
    @Published private(set) var checking = false
    @Published private(set) var statusConfirmed = false
    @Published private(set) var reconnecting = false
    @Published var message: String?
    private let client = C2CClient()
    private let checker = ConnectionChecker()
    private let gateSourceID: String?
    private var revision = 0
    private var reconnectPolicy = GatewayReconnectPolicy()
    private var wakeObserver: AnyCancellable?

    var connectionState: GatewayConnectionState {
        .make(status: statusConfirmed ? status : nil, diagnostics: diagnostics, checking: checking)
    }
    var usable: Bool { connectionState == .ready }
    var automaticallyReconnects: Bool { status?.reconnectEnabled != false }
    var waitingToReconnect: Bool {
        statusConfirmed && status?.desiredRunning == true && automaticallyReconnects && !usable
            && status?.state != "unknown"
    }
    var connectionTitle: String {
        if reconnecting { return "重新連線中…" }
        if diagnostics?.hasPublicDNSFailure == true && !checking { return "暫時搵唔到連線地址" }
        if waitingToReconnect && !checking { return "等待重新連線" }
        return connectionState.title
    }
    var connectionHint: String {
        if diagnostics?.hasPublicDNSFailure == true { return publicDNSHint }
        if waitingToReconnect { return "恢復後沿用原有 ChatGPT 設定。" }
        if usable {
            return (status?.tokenCount ?? 0) > 0
                ? (status?.authorizationVersion == 2 ? "原有連線可用；分享變更會喺下一次請求生效。" : "原有連線可用；重啟共用連線可套用新版授權。")
                : "Mac 已就緒；首次使用請完成下方配對。"
        }
        if connectionState == .stopped && status?.stableMCPURL != nil { return "開啟後沿用原有地址同授權。" }
        return ""
    }
    var userFacingMessage: String? {
        guard let message else { return nil }
        if status?.transport == "embedded", status?.transportSetup?.state != "ready" {
            return status?.transportSetup?.message ?? "請完成內置連線登入，再重新檢查。"
        }
        if diagnostics?.hasPublicDNSFailure == true { return publicDNSHint }
        if message.contains("地址同原有") || message.contains("固定地址同原有") {
            return "固定地址唔一致，請連返原有 Tailscale 帳戶／裝置。原有設定已保留。"
        }
        if StableConnectionView.approvalLink(in: message) != nil { return "需要完成 Tailscale 授權，請按下方連結。" }
        if message.contains("Tailscale") && waitingToReconnect {
            return status?.transport == "embedded" ? "內置連線暫時未通，App 會自動再試。" : "請先開啟並連接 Tailscale；App 會自動再試。"
        }
        if waitingToReconnect { return "連線暫時未通，App 會自動再試。" }
        return "暫時未能連線，請按「重新檢查」；詳情已收喺連線詳細資料。"
    }

    private var publicDNSHint: String {
        "Mac 暫時搵唔到公開地址。稍後再檢查；如有開 VPN，可暫停後再試。毋須重新登入或下載 Tailscale。"
    }

    init(automaticallyRefresh: Bool = true, gateSourceID: String? = nil) {
        self.gateSourceID = gateSourceID
        guard automaticallyRefresh && gateSourceID == nil else { return }
        Task { [weak self] in
            while let self {
                if !self.working {
                    await self.refresh()
                    if self.statusConfirmed && self.status?.running == true && self.status?.connectionRemembered == false {
                        _ = await self.perform("remember-running")
                    }
                    await self.recoverIfNeeded()
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.working else { return }
                    self.reconnectPolicy.reset()
                    await self.refresh()
                    await self.recoverIfNeeded()
                }
            }
    }

    func refresh() async {
        guard !checking else { return }
        let currentRevision = revision
        checking = true
        defer { if currentRevision == revision { checking = false } }
        do {
            let response = try await client.gateway("status", sourceID: gateSourceID)
            let status = try JSONDecoder().decode(GatewayStatus.self, from: response)
            guard currentRevision == revision else { return }
            if self.status?.running != status.running || self.status?.gatewayID != status.gatewayID
                || self.status?.port != status.port || self.status?.mcpURL != status.mcpURL
                || self.status?.tunnel?.running != status.tunnel?.running
                || self.status?.tunnel?.url != status.tunnel?.url {
                diagnostics = nil
            }
            self.status = status
            statusConfirmed = true
            folderCodes = folderCodes.filter { id, code in
                status.running == true && code.expiration > Date()
                    && status.roots.contains { $0.id == id && $0.codeRequired == true }
                    && status.folderAccess?.contains { $0.workspaceID == id && $0.codeActive } == true
            }
            if let pairing, pairing.expiration <= Date() || status.pairingActive == false { self.pairing = nil }
            if let id = status.gatewayID {
                let checked = await checker.check(workspaceID: id, status: status.bridgeStatus, service: gateSourceID == nil ? "boundas-gateway" : "c2c-bridge")
                guard currentRevision == revision else { return }
                diagnostics = checked
                if usable {
                    reconnectPolicy.reset()
                    if !working { message = nil }
                }
            } else { diagnostics = nil }
        } catch {
            guard currentRevision == revision else { return }
            diagnostics = nil
            statusConfirmed = false
            message = error.localizedDescription
        }
    }

    @discardableResult
    func perform(_ action: String, selectedIDs: [String]? = nil, sourceID: String? = nil,
                 workspaceID: String? = nil, codeRequired: Bool? = nil, reconnectEnabled: Bool? = nil,
                 clientID: String? = nil, confirmedExternal: Bool? = nil) async -> Bool {
        guard !working else { return false }
        working = true
        operation = action
        revision += 1
        checking = false
        message = nil
        defer { working = false; operation = nil }
        do {
            let input: Data?
            if let confirmedExternal { input = try JSONEncoder().encode(["confirmedExternal": confirmedExternal]) }
            else if let clientID { input = try JSONEncoder().encode(["clientID": clientID]) }
            else if let reconnectEnabled { input = try JSONEncoder().encode(["enabled": reconnectEnabled]) }
            else if let workspaceID {
                struct FolderInput: Encodable { let workspaceID: String; let required: Bool? }
                input = try JSONEncoder().encode(FolderInput(workspaceID: workspaceID, required: codeRequired))
            }
            else if let sourceID { input = try JSONEncoder().encode(["sourceID": sourceID]) }
            else if let selectedIDs { input = try JSONEncoder().encode(["selectedIDs": selectedIDs]) }
            else if action == "confirm", usable, let url = status?.mcpURL { input = try JSONEncoder().encode(["url": url]) }
            else { input = nil }
            let response = try await client.gateway(action, input: input, sourceID: gateSourceID)
            if action == "pair" { pairing = try JSONDecoder().decode(GatewayPairing.self, from: response) }
            else if ["configure", "remove-root", "stop", "logout", "revoke"].contains(action) { pairing = nil }
            if action == "folder-code" {
                let code = try JSONDecoder().decode(GatewayFolderCode.self, from: response)
                folderCodes[code.workspaceID] = code
            } else if ["code-policy", "lock-folder"].contains(action), let workspaceID {
                folderCodes[workspaceID] = nil
            } else if ["stop", "logout", "revoke"].contains(action) { folderCodes.removeAll() }
            let loginSetup = action == "login" ? try JSONDecoder().decode(GatewayStatus.self, from: response).transportSetup : nil
            await refresh()
            if let loginSetup { status?.transportSetup = loginSetup }
            if ["start", "reconnect", "recover"].contains(action) {
                for _ in 0..<3 where !usable {
                    try await Task.sleep(for: .seconds(3))
                    await refresh()
                }
                if !usable {
                    if status?.transport == "embedded" {
                        message = status?.transportSetup?.state == "ready"
                            ? "內置裝置已登入，但公開地址暫時未通。請重新檢查；原有設定同授權會保留。"
                            : "暫時未能連線。請完成內置連線登入及授權，再重新檢查；原有 ChatGPT 設定同授權會保留。"
                    } else {
                        message = "暫時未能連線。請確認 Tailscale 已連線；原有 ChatGPT 設定同授權會保留。"
                    }
                }
            }
            return true
        } catch {
            message = error.localizedDescription
            await refresh()
            return false
        }
    }

    func repair() async {
        guard !working else { return }
        guard statusConfirmed, let status, status.state != "unknown", status.running != nil else {
            await refresh()
            return
        }
        reconnectPolicy.reset()
        _ = await perform(status.running == true ? "reconnect" : "start")
    }

    func restart() async {
        guard !working, statusConfirmed, status?.state != "unknown", status?.running != nil else { return }
        restarting = true
        defer { restarting = false }
        if status?.running == true {
            guard await perform("stop") else { return }
        }
        _ = await perform("start")
    }

    func setAutomaticReconnect(_ enabled: Bool) async {
        _ = await perform("connection-settings", reconnectEnabled: enabled)
        reconnectPolicy.reset()
    }

    private func recoverIfNeeded() async {
        guard reconnectPolicy.shouldAttempt(status: status, usable: usable, confirmed: statusConfirmed,
                                             busy: working || checking) else { return }
        reconnecting = true
        defer { reconnecting = false }
        _ = await perform("recover")
    }

    func signInTunnel() async {
        guard await perform("login") else { return }
        if let url = status?.transportSetup?.actionURL { NSWorkspace.shared.open(url) }
    }

    func copyURL(openChatGPT: Bool = false) {
        guard usable, let url = status?.mcpURL else { return }
        copy(url)
        if openChatGPT { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/plugins")!) }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
