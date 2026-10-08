import SwiftUI

struct SharedGatewayView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gateway: SharedGatewayStore
    @Binding var selected: Set<String>
    @State private var confirmRevoke = false
    @State private var testCopied = false
    @State private var showPairing = false
    @State private var setupNotice: String?
    @State private var expandedOverride: Bool?
    @State private var showAdvanced = false
    @State private var showTunnelManagement = false

    private var saved: Set<String> { Set((gateway.status?.roots ?? []).map { $0.sourceID.lowercased() }) }
    private var changed: Bool { selected != saved }
    private var testPrompt: String {
        "請用 Boundas Gate 共用連線，先 call list_workspaces，再分別列出每個已授權 Folder 最上層嘅檔案名稱。唔好修改任何檔案。"
    }

    var body: some View {
        ScrollView {
            connectionControls
                .padding(.horizontal, 28).padding(.vertical, 20)
        }
        .navigationTitle("Main Gate")
        .sheet(isPresented: $showTunnelManagement) {
            TunnelManagementView(gateway: gateway)
        }
        .onAppear {
            showPairing = gateway.status?.tokenCount == 0 || gateway.pairing != nil
        }
        .onChange(of: gateway.status?.tokenCount) { _, count in
            if count == 0 { showPairing = true }
        }
        .onChange(of: journey.presentationKey) { _, _ in expandedOverride = nil }
        .onChange(of: gateway.pairing?.pairingCode) { _, code in
            if code != nil { showPairing = true; expandedOverride = true }
        }
        .confirmationDialog("撤銷全部共用連線授權？", isPresented: $confirmRevoke) {
            Button("撤銷授權", role: .destructive) { Task { _ = await gateway.perform("revoke") } }
        } message: { Text("Main Gate MCP Connections 即時失去授權；Side Gates 不受影響。") }
        .alert("下一步", isPresented: Binding(
            get: { setupNotice != nil },
            set: { if !$0 { setupNotice = nil } }
        )) {
            Button("知道了", role: .cancel) { setupNotice = nil }
        } message: { Text(setupNotice ?? "") }
    }

    private var journey: GateConnectionJourney {
        .make(status: gateway.status, diagnostics: gateway.diagnostics, confirmed: gateway.statusConfirmed,
              busy: gateway.working || gateway.checking || gateway.reconnecting, usable: gateway.usable)
    }

    private var opening: Bool {
        gateway.restarting || gateway.reconnecting || ["start", "reconnect", "recover"].contains(gateway.operation ?? "")
    }

    private var detailsExpanded: Bool {
        !journey.isReady || opening || (expandedOverride ?? journey.hasAIWarning)
    }

    private var gateTitle: String {
        if gateway.restarting || gateway.reconnecting || ["reconnect", "recover"].contains(gateway.operation ?? "") {
            return "Reopening Gate…"
        }
        if gateway.operation == "start" { return "Opening Gate…" }
        if journey.isOpen { return "Gate Open" }
        if gateway.statusConfirmed, gateway.status?.running == false,
           gateway.status?.stableMCPURL != nil { return "Gate Closed" }
        if journey.nodes.contains(.attention) { return "Gate Needs Attention" }
        return "Setup Required"
    }

    private var summaryDetail: String {
        let folders = gateway.status?.roots.count ?? 0
        let connections = journey.aiConnections.filter(\.isAuthorized).count
        var text = "\(connections) MCP \(connections == 1 ? "Connection" : "Connections") · \(folders) Folders shared"
        if journey.attentionCount > 0 { text += " · \(journey.attentionCount) needs attention" }
        return text
    }

    private var stageExplanation: String? {
        if changed { return "請先儲存左邊嘅 Folder 分享變更。" }
        switch journey.activeStage {
        case .local:
            if journey.nodes[0] == .attention { return "Boundas Gate isn't responding on this Mac." }
            return gateway.status?.running == false ? "Open Boundas Gate on this Mac." : "Checking Boundas Gate on this Mac."
        case .tunnel:
            if let setup = gateway.status?.transportSetup, setup.state != "ready" {
                return "Your Gate can't be reached from ChatGPT or Claude yet.\nYour existing setup is preserved."
            }
            return journey.nodes[1] == .attention
                ? "Your Gate can't be reached from ChatGPT or Claude yet.\nYour existing setup is preserved."
                : "Preparing secure access to your Gate."
        case .aiConnection:
            if gateway.status?.aiConnections == nil { return "Checking which AI apps can use your Gate." }
            if journey.aiConnections.isEmpty { return "Connect ChatGPT, Claude, or another MCP-compatible app." }
            return journey.isReady ? "Some AI apps need attention. Other authorized apps can still use your Gate."
                : "Set up or renew an AI app's access to your Gate."
        case .ready:
            return nil
        }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if journey.isReady && !opening { expandedOverride = !detailsExpanded }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        GateJourneyDot(state: journey.isOpen ? .current : opening ? .current
                                       : journey.nodes.contains(.attention) ? .attention : .pending,
                                       pulses: !detailsExpanded)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(gateTitle).font(.system(size: 17, weight: .medium))
                            Text(summaryDetail).font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show connection details")
                Menu {
                    Button(detailsExpanded ? "Hide connection details" : "Show connection details") {
                        expandedOverride = !detailsExpanded
                    }.disabled(!journey.isReady || opening)
                    Button("Set Up MCP Connection") { beginAISetup() }
                        .disabled(!gateway.usable || gateway.working || gateway.checking || changed )
                    Divider()
                    Button("Manage Tunnel…") { showTunnelManagement = true }
                    Button("Advanced…") { showAdvanced = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Connection actions")
                .popover(isPresented: $showAdvanced, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Advanced").font(.headline)
                        advancedConnectionControls.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18).frame(width: 360)
                }
            }
            if detailsExpanded {
                GateConnectionStepper(journey: journey, explanation: stageExplanation,
                                      showConnections: journey.activeStage == .aiConnection || expandedOverride == true || showPairing) {
                    journeyAction
                } connections: {
                    VStack(alignment: .leading, spacing: 12) {
                        aiConnectionRows
                        if gateway.usable { aiAuthorizationControls }
                    }
                } tunnel: {
                    tunnelDetails
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tunnelDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Manage Tunnel…") { showTunnelManagement = true }
                .buttonStyle(.borderless).controlSize(.small)
            if let url = gateway.status?.mcpURL {
                Text("Server URL").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    Text(url).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { gateway.copyURL() } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).help("Copy URL").accessibilityLabel("Copy URL")
                    .disabled(!gateway.usable)
                }
            }
        }
    }

    private var aiAuthorizationControls: some View {
        DisclosureGroup("配對／授權", isExpanded: $showPairing) {
            VStack(alignment: .leading, spacing: 12) {
                if let pairing = gateway.pairing {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil(pairing.expiration.timeIntervalSince(context.date))))
                        if remaining > 0 {
                            HStack(spacing: 16) {
                                Text(pairing.pairingCode)
                                    .font(.system(.title, design: .monospaced).bold()).textSelection(.enabled)
                                Button("複製") { gateway.copy(pairing.pairingCode) }
                            }
                            Text("目前分享：\((gateway.status?.roots.map(\.name) ?? pairing.roots.map(\.name)).joined(separator: "、"))")
                                .font(.callout)
                            Text(gateway.status?.authorizationVersion == 2
                                 ? "此配對連接 Boundas Gate；之後確認分享嘅 Folders 亦可讀取。"
                                 : "請先套用新版授權，新增分享嘅 Folders 先會自動生效。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(remaining / 60):\(String(format: "%02d", remaining % 60)) 後過期")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("配對碼已過期，請重新產生。").foregroundStyle(.orange)
                        }
                    }
                }
                HStack {
                    Button(gateway.pairing == nil ? "產生配對碼" : "重新產生") {
                        Task { _ = await gateway.perform("pair") }
                    }
                    .disabled(gateway.working || changed )
                    if gateway.status?.addressConfirmed != true {
                        Button("已完成設定") { Task { _ = await gateway.perform("confirm") } }
                            .disabled(gateway.working)
                    }
                }
                Button(testCopied ? "已複製 · 再複製測試句子" : "複製測試句子") {
                    gateway.copy(testPrompt); testCopied = true
                }
                DisclosureGroup("管理授權") {
                    Button("撤銷全部授權…", role: .destructive) { confirmRevoke = true }
                        .disabled(gateway.working).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
    }

    private var aiConnectionRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !journey.aiConnections.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(journey.aiConnections) { connection in
                            HStack(spacing: 8) {
                                GateJourneyDot(state: connection.isAuthorized ? .completed : connection.needsAttention ? .attention : .pending, pulses: false)
                                    .frame(width: 16, height: 24)
                                Text(connection.name).font(.callout).lineLimit(1).help(connection.name)
                                Spacer(minLength: 8)
                                Text(connection.statusLabel).font(.caption)
                                    .foregroundStyle(connection.needsAttention ? Color.orange : Color.secondary)
                                    .help(connection.reason ?? "Authorization status is unknown.")
                                if !connection.isAuthorized {
                                    Button(connection.needsAttention ? "Fix" : "Set Up") { beginAISetup(connection) }
                                        .controlSize(.small)
                                        .disabled(!gateway.usable || gateway.working || gateway.checking || changed )
                                    Button {
                                        Task { _ = await gateway.perform("remove-client", clientID: connection.clientID) }
                                    } label: {
                                        Image(systemName: "trash").font(.system(size: 11))
                                            .frame(width: 20, height: 22)
                                    }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .help("Remove registration").accessibilityLabel("Remove registration for \(connection.name)")
                                    .disabled(gateway.working || gateway.status?.clientManagementVersion != 1)
                                }
                            }
                            .help("Client: \(connection.clientID). Status reflects authorization, not live app health.")
                        }
                    }
                }
                .frame(height: min(180, CGFloat(journey.aiConnections.count) * 32))
                Text("Status reflects authorization.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var journeyAction: some View {
        if !journey.isReady {
            if journey.activeStage == .aiConnection {
                if gateway.status?.aiConnections == nil {
                    Button("Recheck") { Task { await gateway.refresh() } }
                        .disabled(gateway.working || gateway.checking)
                } else if journey.aiConnections.isEmpty {
                    Button("Set Up") { beginAISetup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(gateway.working || gateway.checking || changed )
                }
            } else if journey.activeStage == .ready {
                if gateway.statusConfirmed {
                    Button("Recheck") { Task { await gateway.refresh() } }
                        .disabled(gateway.working || gateway.checking)
                }
            } else if let setup = gateway.status?.transportSetup, setup.state != "ready", let url = setup.actionURL {
                Link("Continue Setup", destination: url).buttonStyle(.borderedProminent)
                    .disabled(gateway.working || gateway.checking)
            } else if let message = gateway.message, let url = StableConnectionView.approvalLink(in: message) {
                Link("Continue Setup", destination: url).buttonStyle(.borderedProminent)
                    .disabled(gateway.working || gateway.checking)
            } else {
                Button(journey.nodes[journey.activeStage.rawValue] == .attention ? "Repair" : "Continue Setup") {
                    Task {
                        if journey.activeStage == .tunnel, gateway.status?.transport == "embedded",
                           gateway.status?.transportSetup?.state != "ready", !changed {
                            showTunnelManagement = true
                        } else { await runPrimaryAction() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(gateway.working || gateway.checking)
            }
        }
    }

    private func beginAISetup(_ connection: GatewayAIConnection? = nil) {
        showPairing = true
        expandedOverride = true
        let opensChatGPT = connection == nil || connection?.name.localizedCaseInsensitiveContains("ChatGPT") == true
        gateway.copyURL(openChatGPT: opensChatGPT)
        if let connection, !opensChatGPT {
            setupNotice = "已複製連線地址。請喺 \(connection.name) 重新授權；配對碼可以喺 MCP Connection 產生。"
        }
    }

    private var advancedConnectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if gateway.statusConfirmed && (gateway.status?.running == true || gateway.status?.desiredRunning == true) {
                    if gateway.status?.running == true && gateway.status?.state != "unknown" {
                        Button("Restart") { Task { await gateway.restart() } }
                            .disabled(gateway.working || gateway.checking || changed)
                    }
                    Button("Stop") { Task { _ = await gateway.perform("stop") } }
                        .disabled(gateway.working)
                }
                Button("Recheck") { Task { await gateway.refresh() } }
                    .disabled(gateway.working || gateway.checking)
            }
            .controlSize(.small)
            Toggle("斷線後自動恢復", isOn: Binding(
                get: { gateway.automaticallyReconnects },
                set: { enabled in Task { await gateway.setAutomaticReconnect(enabled) } }
            ))
            .toggleStyle(.checkbox)
            .disabled(gateway.working || !gateway.statusConfirmed )
            .help("App 運行時自動恢復已開啟嘅共用連線；手動停止後唔會自行開啟。")
            Text(gateway.connectionTitle)
            if gateway.status?.transport == "external" { Text("沿用原有 Tailscale 連線及地址。") }
            if gateway.status?.transport == "embedded", let setup = gateway.status?.transportSetup,
               setup.state != "ready" {
                Text(setup.message)
                if setup.loginURL != nil {
                    Text("毋須下載 Tailscale。首次登入後如見到下載頁，請返嚟再按 Continue Setup 完成授權。")
                }
            }
            if !gateway.connectionHint.isEmpty { Text(gateway.connectionHint) }
            if gateway.statusConfirmed && gateway.status?.running == true && gateway.status?.authorizationVersion != 2 {
                Button("套用新版授權") { Task { await gateway.restart() } }
                    .disabled(gateway.working || gateway.checking || changed)
                    .help("重啟共用服務，保留原有 MCP 授權同固定地址。")
            }
            if gateway.message != nil, gateway.userFacingMessage != gateway.connectionHint {
                Text(gateway.userFacingMessage ?? "").foregroundStyle(.orange)
            }
            if let reason = gateway.status?.reason {
                Text(reason).textSelection(.enabled)
            }
        }
    }

    private func runPrimaryAction() async {
        switch gateway.connectionState {
        case .checking, .unknown:
            await gateway.refresh()
            if !gateway.statusConfirmed {
                setupNotice = "暫時未能確認連線狀態，請稍後按「重新檢查」。"
            }
        case .stopped, .needsRepair:
            if changed {
                guard await gateway.perform("configure", selectedIDs: selected.sorted()) else {
                    setupNotice = gateway.userFacingMessage ?? "未能儲存分享清單，請重新檢查再試。"
                    return
                }
            }
            await gateway.repair()
            if !gateway.usable {
                showTunnelManagement = true
            } else if gateway.status?.tokenCount == 0 {
                showPairing = true
                setupNotice = "Gate 已開啟。下一步喺 MCP Connection 產生配對碼，再去 AI app 加入連線。"
            }
        case .ready:
            gateway.copyURL(openChatGPT: true)
        }
    }

}
