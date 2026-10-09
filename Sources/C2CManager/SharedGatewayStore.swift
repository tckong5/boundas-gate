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
    @Published private(set) var checkingInBackground = false
    @Published private(set) var statusConfirmed = false
    @Published private(set) var reconnecting = false
    @Published var message: String?
    private let client: any GatewayClient
    private let checkConnection: (String, WorkspaceStatus, String) async -> ConnectionDiagnostics
    private let diagnosticsLogFile: URL?
    private var observationEnabled = true
    private let gateSourceID: String?
    private var revision = 0
    private var lastConnectionSummary: String?
    private var reconnectPolicy = GatewayReconnectPolicy()
    private var wakeObserver: AnyCancellable?
    private var automaticRefreshStarted = false

    var connectionState: GatewayConnectionState {
        .make(status: statusConfirmed ? status : nil, diagnostics: diagnostics, checking: visiblyChecking)
    }
    var visiblyChecking: Bool { checking && !checkingInBackground }
    var usable: Bool { connectionState == .ready }
    var automaticallyReconnects: Bool { status?.reconnectEnabled != false }
    var waitingToReconnect: Bool {
        statusConfirmed && status?.desiredRunning == true && automaticallyReconnects && !usable
            && status?.state != "unknown"
    }
    var connectionTitle: String {
        if reconnecting { return "重新連線中…" }
        if diagnostics?.hasPublicDNSFailure == true && !visiblyChecking { return "暫時搵唔到連線地址" }
        if waitingToReconnect && !visiblyChecking { return "等待重新連線" }
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
        if SecureAccessPresentation.approvalLink(in: message) != nil { return "需要完成 Tailscale 授權，請按下方連結。" }
        if message.contains("Tailscale") && waitingToReconnect {
            return status?.transport == "embedded" ? "內置連線暫時未通，App 會自動再試。" : "請先開啟並連接 Tailscale；App 會自動再試。"
        }
        if waitingToReconnect { return "連線暫時未通，App 會自動再試。" }
        return "暫時未能連線，請按「重新檢查」；詳情已收喺連線詳細資料。"
    }

    private var publicDNSHint: String {
        "呢部 Mac 暫時搵唔到 Gate 地址。可按 Secure Access 嘅 Repair 清理網絡快取，再重新檢查。"
    }

    init(automaticallyRefresh: Bool = true, gateSourceID: String? = nil,
         client: (any GatewayClient)? = nil,
         connectionCheck: ((String, WorkspaceStatus, String) async -> ConnectionDiagnostics)? = nil,
         diagnosticsLogFile: URL? = nil) {
        self.client = client ?? C2CClient()
        let checker = ConnectionChecker()
        self.checkConnection = connectionCheck ?? { id, status, service in
            await checker.check(workspaceID: id, status: status, service: service)
        }
        self.diagnosticsLogFile = diagnosticsLogFile
        self.gateSourceID = gateSourceID
        guard automaticallyRefresh && gateSourceID == nil else { return }
        startAutomaticRefresh()
    }

    func startAutomaticRefresh() {
        guard gateSourceID == nil, !automaticRefreshStarted else { return }
        automaticRefreshStarted = true
        Task { [weak self] in
            while let self {
                if !self.working {
                    await self.refresh(background: true)
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
                    await self.refresh(background: true)
                    await self.recoverIfNeeded()
                }
            }
    }

    /// Retire this Side owner's observations before the backend decommission.
    /// Pending responses are ignored and this instance cannot restart/pair again.
    func suspendForDecommission() {
        guard gateSourceID != nil else { return }
        observationEnabled = false
        revision += 1
        checking = false
        checkingInBackground = false
        statusConfirmed = false
        status = nil
        diagnostics = nil
        pairing = nil
        folderCodes.removeAll()
        message = nil
    }

    func refresh(background: Bool = false) async {
        guard observationEnabled else { return }
        guard !checking else {
            // Reuse an ongoing background check when the user clicks refresh,
            // and keep its visual feedback active until that check finishes.
            if !background { checkingInBackground = false }
            return
        }
        let currentRevision = revision
        checkingInBackground = background
        checking = true
        defer {
            if currentRevision == revision {
                checking = false
                checkingInBackground = false
            }
        }
        do {
            let response = try await client.gateway("status", input: nil, sourceID: gateSourceID)
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
                let checked = await checkConnection(id, status.bridgeStatus, gateSourceID == nil ? "boundas-gateway" : "c2c-bridge")
                guard currentRevision == revision else { return }
                diagnostics = checked
                // Record state transitions, not every background poll. These
                // checks contain no credentials or file-operation responses.
                let summary = GatewayDiagnosticsLog.connectionSummary(checked)
                if summary != lastConnectionSummary {
                    GatewayDiagnosticsLog.record(.init(code: checked.isUsable ? 0 : 1, output: "", error: summary),
                                                 action: "connection-check",
                                                 file: diagnosticsLogFile ?? AppDataPaths.current.directory.appendingPathComponent("diagnostics/gateway-command.log"))
                    lastConnectionSummary = summary
                }
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
                 clientID: String? = nil, confirmedExternal: Bool? = nil, sessionIDs: [String]? = nil) async -> Bool {
        guard observationEnabled, !working else { return false }
        working = true
        operation = action
        revision += 1
        let currentRevision = revision
        checking = false
        checkingInBackground = false
        message = nil
        defer { working = false; operation = nil }
        do {
            let input: Data?
            if let sessionIDs { input = try JSONEncoder().encode(["sessionIDs": sessionIDs]) }
            else if let confirmedExternal { input = try JSONEncoder().encode(["confirmedExternal": confirmedExternal]) }
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
            guard observationEnabled, currentRevision == revision else { return false }
            if action == "pair" { pairing = try JSONDecoder().decode(GatewayPairing.self, from: response) }
            else if ["configure", "remove-root", "stop", "logout", "revoke", "cancel-setup"].contains(action) { pairing = nil }
            if action == "folder-code" {
                let code = try JSONDecoder().decode(GatewayFolderCode.self, from: response)
                folderCodes[code.workspaceID] = code
            } else if ["code-policy", "lock-folder"].contains(action), let workspaceID {
                folderCodes[workspaceID] = nil
            } else if ["stop", "logout", "revoke"].contains(action) { folderCodes.removeAll() }
            let loginSetup = ["login", "prepare-access", "migrate-shared"].contains(action) ? try JSONDecoder().decode(GatewayStatus.self, from: response).transportSetup : nil
            // Open the command's URL immediately, before health checks or a
            // concurrent status refresh can replace this login response.
            if action == "login" || action == "migrate-shared" {
                if let url = loginSetup?.actionURL {
                    guard NSWorkspace.shared.open(url) else {
                        throw C2CClientError.commandFailed("未能開啟瀏覽器。請確認已設定預設瀏覽器，再按 Sign In。")
                    }
                } else if action == "login" && loginSetup?.state != "ready" {
                    throw C2CClientError.commandFailed("未能取得 Tailscale 登入網址。請檢查網絡後再按 Sign In。")
                }
            }
            await refresh()
            if let loginSetup { status?.transportSetup = loginSetup }
            if ["start", "reconnect", "recover"].contains(action), status?.localOnly != true {
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
            guard observationEnabled, currentRevision == revision else { return false }
            let failure = error.localizedDescription
            await refresh()
            message = failure
            return false
        }
    }

    func repair() async {
        guard !working else { return }
        if status?.running == true, status?.tunnel?.running == true,
           diagnostics?.hasPublicDNSFailure == true, diagnostics?.address.passed == true {
            await refresh()
            if diagnostics?.hasPublicDNSFailure == true { message = publicDNSHint }
            return
        }
        guard statusConfirmed, let status, status.state != "unknown", status.running != nil else {
            await refresh()
            return
        }
        reconnectPolicy.reset()
        _ = await perform(status.running == true ? "reconnect" : "start")
    }

    var canRepairDNSCache: Bool {
        statusConfirmed && status?.running == true && status?.tunnel?.running == true
            && diagnostics?.hasPublicDNSFailure == true && diagnostics?.address.passed == true
    }

    /// Called only after the user confirms the cache repair in the Gate UI.
    func repairDNSCache() async {
        guard !working, canRepairDNSCache else { return }
        working = true
        operation = "repair-dns"
        revision += 1
        // A background observation must not silently swallow a confirmed
        // Repair click. Invalidate it just as other explicit actions do.
        checking = false
        checkingInBackground = false
        message = nil
        defer { working = false; operation = nil }
        let result = await DNSCacheRepair.run()
        guard result != .cancelled else { return }
        await refresh()
        if result == .failed {
            message = "未能清理網絡快取。請稍後再按 Repair。"
        } else if result == .busy {
            message = "另一個 Gate 正在清理網絡快取，請稍後重新檢查。"
        } else if diagnostics?.hasPublicDNSFailure == true {
            message = "已清理網絡快取，但仍然搵唔到 Gate 地址。請稍後重新檢查；可能仍有 DNS 或網絡問題。"
        }
    }

    func restart() async {
        guard !working, statusConfirmed, status?.state != "unknown", status?.running != nil else { return }
        restarting = true
        defer { restarting = false }
        if status?.running == true {
            guard await perform("stop") else { return }
        }
        _ = await perform(status?.localOnly == true ? "start-local" : "reconnect")
    }

    func setAutomaticReconnect(_ enabled: Bool) async {
        _ = await perform("connection-settings", reconnectEnabled: enabled)
        reconnectPolicy.reset()
    }

    func recoverIfNeeded() async {
        guard status?.endpointMigrationPending != true, observationEnabled, reconnectPolicy.shouldAttempt(status: status, usable: usable, confirmed: statusConfirmed,
                                             busy: working || checking, diagnostics: diagnostics) else { return }
        reconnecting = true
        defer { reconnecting = false }
        _ = await perform("recover")
    }

    @discardableResult
    func signInTunnel() async -> Bool {
        await perform(status?.endpointMigrationPending == true ? "migrate-shared" : "login")
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
