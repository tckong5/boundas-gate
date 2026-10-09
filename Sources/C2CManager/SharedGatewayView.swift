import SwiftUI

struct SharedGatewayView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gateway: SharedGatewayStore
    @Binding var selected: Set<String>
    @State private var showAdvanced = false
    var body: some View {
        ScrollView {
            GateConnectionContent(gateway: gateway, selected: $selected, context: .main, advanced: $showAdvanced, mapStore: store)
                .padding(.horizontal, 28).padding(.vertical, 20)
        }
        .navigationTitle("Main Gate")
    }
}

/// Main and Side Gates render the same journey; only the Gate context/data differ.
struct GateConnectionContent: View {
    @ObservedObject var gateway: SharedGatewayStore
    @Binding var selected: Set<String>
    @State private var confirmRevoke = false
    @StateObject private var setup: AISetupStore
    let context: GateUIContext
    @State private var setupExpanded = false
    @State private var confirmTunnelLogout = false
    @State private var confirmDNSRepair = false
    @State private var confirmSharedMigration = false
    @State private var revokeConnection: GatewayAIConnection?
    @State private var setupNotice: String?
    @State private var expandedOverride: Bool?
    @Binding private var showAdvanced: Bool
    @State private var showTunnelManagement = false
    @State private var refreshMinimumSpin = false
    @State private var detailConnectionID: String?
    private let mapStore: WorkspaceStore?

    init(gateway: SharedGatewayStore, selected: Binding<Set<String>>, context: GateUIContext, advanced: Binding<Bool>, mapStore: WorkspaceStore? = nil) {
        self.gateway = gateway
        _selected = selected
        self.context = context
        self.mapStore = mapStore
        _showAdvanced = advanced
        _setup = StateObject(wrappedValue: AISetupStore(file: context.setupFile()))
    }

    private var saved: Set<String> { Set((gateway.status?.roots ?? []).map { $0.sourceID.lowercased() }) }
    private var changed: Bool { !context.isSide && selected != saved }
    var body: some View {
        connectionControls
        .sheet(isPresented: $showTunnelManagement) {
            TunnelManagementView(gateway: gateway)
        }
        .onAppear { reconcileSetup() }
        .onChange(of: gateway.status?.aiConnections) { _, _ in reconcileSetup() }
        .onChange(of: gateway.status?.gatewayID) { _, _ in reconcileSetup() }
        .onChange(of: setup.draft?.stage) { _, stage in
            if stage == .completed { setupExpanded = false }
            if !context.isSide && (stage == .completed || stage == nil) { expandedOverride = nil }
        }
        .onChange(of: gateway.status?.pairingActive) { _, _ in reconcileSetup() }
        .onChange(of: journey.presentationKey) { _, _ in
            if !setupExpanded { expandedOverride = nil }
        }
        .confirmationDialog("Repair Secure Access?", isPresented: $confirmDNSRepair) {
            Button("Refresh Network Cache") { Task { await gateway.repairDNSCache() } }
        } message: {
            Text("Clear this Mac's DNS cache, then check this Gate again. macOS may ask for an administrator password.")
        }
        .confirmationDialog("Sign Out of Tailscale?", isPresented: $confirmTunnelLogout) {
            Button("Sign Out", role: .destructive) {
                Task { _ = await gateway.perform("logout", confirmedExternal: gateway.status?.transport == "external") }
            }
        } message: {
            Text(gateway.status?.transport == "external"
                 ? "This stops this Gate and signs this Mac out of Tailscale. Side Gates and other services using this device may also stop. Folders, MCP authorizations and the saved address are preserved."
                 : gateway.status?.sharedTunnel == true
                 ? "This signs out shared Secure Access for Main Gate and all Side Gates using it. Folders, MCP authorizations and saved addresses are preserved."
                 : "This stops this Gate and signs out its secure access. Folders, MCP authorizations and the saved address are preserved. Other Gates are unaffected.")
        }
        .confirmationDialog("Use Shared Secure Access?", isPresented: $confirmSharedMigration) {
            Button("Use Shared Secure Access") { Task { _ = await gateway.perform("migrate-shared") } }
        } message: {
            Text(context.isSide ? "This Side Gate will use Main Gate’s Tailscale sign-in and domain. Its Server URL will change: update the URL in each AI app; the app may require authorization again. Folder permissions and other Gates are preserved." : "This Main Gate will use bundled Shared Secure Access. Its public MCP URL will change; update the Server URL in ChatGPT. Gate identity, Folders and OAuth registrations are preserved. The old external Tailscale device is not deleted.")
        }
        .confirmationDialog("Remove MCP Connection?", isPresented: Binding(
            get: { revokeConnection != nil }, set: { if !$0 { revokeConnection = nil } }
        )) {
            if let connection = revokeConnection {
                Button("Revoke and Remove", role: .destructive) {
                    Task { _ = await gateway.perform("revoke-client", clientID: connection.clientID) }
                    revokeConnection = nil
                }
            }
        } message: { Text("This revokes this app’s access, refresh credentials and temporary Folder access for this Gate. Other apps and Gates are unaffected.") }
        .confirmationDialog("Revoke all \(context.title) authorizations?", isPresented: $confirmRevoke) {
            Button("撤銷授權", role: .destructive) { Task { _ = await gateway.perform("revoke") } }
        } message: { Text("Only this Gate’s MCP authorizations will be revoked. Other Gates are unaffected.") }
        .alert("下一步", isPresented: Binding(
            get: { setupNotice != nil },
            set: { if !$0 { setupNotice = nil } }
        )) {
            Button("知道了", role: .cancel) { setupNotice = nil }
        } message: { Text(setupNotice ?? "") }
    }

    private var journey: GateConnectionJourney {
        .make(status: gateway.status, diagnostics: gateway.diagnostics, confirmed: gateway.statusConfirmed,
              busy: gateway.working || gateway.visiblyChecking || gateway.reconnecting || refreshMinimumSpin, usable: gateway.usable)
    }

    private var opening: Bool {
        gateway.restarting || gateway.reconnecting || ["start-local", "start", "reconnect", "recover"].contains(gateway.operation ?? "")
    }

    private var detailsExpanded: Bool {
        if mapEligible { return expandedOverride ?? false }
        if !context.isSide && mapStore != nil && (setup.draft?.inProgress == true
            || !setup.completedGateIDs.contains(gateway.status?.gatewayID ?? "")) { return true }
        return !journey.isReady || opening || setupExpanded || refreshMinimumSpin || (expandedOverride ?? journey.hasAIWarning)
    }

    private var mapEligible: Bool {
        !context.isSide && mapStore != nil && journey.isOpen
            && gateway.status?.aiConnections != nil
            && setup.completedGateIDs.contains(gateway.status?.gatewayID ?? "")
            && setup.draft?.inProgress != true
            && !opening && !setupExpanded && !refreshMinimumSpin
            && (!gateway.visiblyChecking || ["configure", "remove-root", "code-policy", "lock-folder", "folder-code",
                                             "revoke", "revoke-client", "remove-client"].contains(gateway.operation ?? ""))
    }

    private var gateTitle: String {
        if mapEligible { return "Gate Open" }
        let title = journey.summaryTitle(opening: gateway.operation == "start-local" || gateway.operation == "start" || gateway.operation == "prepare-access",
            reopening: gateway.restarting || gateway.reconnecting || ["reconnect", "recover"].contains(gateway.operation ?? ""),
            closed: gateway.statusConfirmed && gateway.status?.running == false
                && (gateway.status?.stableMCPURL != nil
                    || gateway.status?.connectionRemembered == true && gateway.status?.desiredRunning == false))
        return title == "Finish setting up your Gate" ? context.setupTitle : title
    }

    private var summaryDetail: String {
        let folders = gateway.status?.roots.count ?? 0
        let connections = journey.aiConnections.filter(\.isAuthorized).count
        var text = "\(connections) MCP \(connections == 1 ? "Connection" : "Connections")"
        if !context.isSide { text += " · \(folders) Folders shared" }
        let attention = mapEligible ? mapAttentionCount : journey.attentionCount
        if attention > 0 { text += " · \(attention) needs attention" }
        return text
    }

    private var mapAttentionCount: Int {
        journey.aiConnections.filter { $0.authorizationState != "revoked" && $0.needsAttention }.count
    }

    private var stageExplanation: String? {
        switch journey.activeStage {
        case .local:
            if journey.nodes[0] == .attention { return "\(context.localTitle) isn't responding on this Mac." }
            if gateway.operation == "start-local" { return "Starting the local MCP host…" }
            return gateway.status?.running == false ? context.localInstruction : "Checking the local MCP host…"
        case .tunnel:
            return nil
        case .aiConnection:
            if setup.draft?.inProgress == true { return nil }
            return gateway.status?.aiConnections == nil ? "Checking which AI apps can use your Gate."
                : "Connect ChatGPT, Claude, or another MCP-compatible app."
        case .ready:
            return nil
        }
    }

    private var aiSetupTitle: String? {
        guard let draft = setup.draft, draft.inProgress else { return nil }
        return draft.app == .other ? "Connect an AI App" : "Connect \(draft.app.title)"
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if (journey.isReady || mapEligible) && !opening { toggleDetails() }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(gateTitle).font(.system(size: 17, weight: .medium))
                            if journey.showsSummaryCounts || mapEligible {
                                Text(summaryDetail).font(.callout).foregroundStyle(.secondary)
                                if context.isSide && journey.isOpen {
                                    Text(secureAccess.description).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show connection details")
                Menu {
                    Button(detailsExpanded ? "Hide connection details" : "Show connection details") {
                        toggleDetails()
                    }.disabled(!(journey.isReady || mapEligible) || opening)
                    if gateway.usable && journey.presentsContent(for: .aiConnection) {
                        Button(setup.draft?.inProgress == true ? "Continue Setup" : "Connect an AI App") { beginAISetup() }
                            .disabled(gateway.working || gateway.visiblyChecking)
                    }
                    if gateway.statusConfirmed && gateway.status?.running == true {
                        Button("Close Gate") { Task { _ = await gateway.perform("stop") } }
                            .disabled(gateway.working || gateway.visiblyChecking || gateway.reconnecting)
                    }
                    Divider()
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
                                      showConnections: journey.presentsContent(for: .aiConnection),
                                      aiConnectionTitle: aiSetupTitle, localTitle: context.localTitle) { stage in
                    if stage == .local && journey.showsLocalCloseControl {
                        Button("Close Gate") { Task { _ = await gateway.perform("stop") } }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(gateway.working || gateway.visiblyChecking || gateway.reconnecting)
                    } else if journey.presentsPrimaryAction(for: stage) {
                        if stage == .tunnel { secureAccessAction }
                        else { journeyAction }
                    }
                } labelAccessory: { stage in
                    if stage == .tunnel { secureAccessRefreshButton }
                } secondary: { stage in
                    if stage == .tunnel && journey.presentsSecondaryActions(for: stage)
                        && (secureAccess.canSignOut || gateway.status?.sharedMigrationAvailable == true || gateway.status?.endpointMigrationPending == true) {
                        secureAccessMenu
                    }
                } connections: {
                    VStack(alignment: .leading, spacing: 14) {
                        aiConnectionRows
                        AIConnectionSetupView(gateway: gateway, setup: setup, expanded: $setupExpanded, context: context)
                    }
                } tunnel: {
                    Text(secureAccessDescription).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(gateway.status?.transportSetup?.message ?? gateway.diagnostics?.publicEndpoint.detail ?? "")
                }
            } else if mapEligible, let mapStore {
                LiveGateActivityMap(store: mapStore, gateway: gateway, connectApp: { beginAISetup() })
                if mapAttentionCount > 0 {
                    HStack {
                        Text("Some authorizations need attention.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Review Connections") { toggleDetails() }.controlSize(.small)
                    }
                }
            } else if let draft = setup.draft, draft.inProgress {
                HStack {
                    Text("\(draft.app.title) · Setup in progress").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue Setup") { beginAISetup() }.controlSize(.small)
                }.padding(.leading, 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var secureAccess: SecureAccessPresentation {
        .make(status: gateway.status, complete: journey.nodes[1] == .completed, message: gateway.message,
              diagnostics: gateway.diagnostics, isSideGate: context.isSide)
    }

    private var secureAccessChecking: Bool {
        refreshMinimumSpin || gateway.visiblyChecking || journey.nodes[1] == .current
    }

    private var secureAccessDescription: String {
        if secureAccessChecking {
            if gateway.operation == "login" {
                return context.isSide ? "Authorizing / checking secure access…" : "Signing in / checking secure access…"
            }
            return "Checking secure access…"
        }
        return secureAccess.description
    }

    @ViewBuilder
    private var secureAccessAction: some View {
        if let action = secureAccess.action, action != .recheck {
            Button(secureAccess.button) { Task { await handleSecureAccess(action) } }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(gateway.working || gateway.visiblyChecking || gateway.reconnecting || refreshMinimumSpin)
        }
    }

    private var secureAccessRefreshButton: some View {
        let spinning = secureAccessChecking
        return Button {
            refreshMinimumSpin = true
            Task {
                // Keep visual feedback for at least three seconds without
                // delaying the actual status result or other Gate actions.
                async let minimumSpin: Void = Task.sleep(for: .seconds(3))
                await gateway.refresh()
                _ = try? await minimumSpin
                refreshMinimumSpin = false
            }
        } label: {
            SecureAccessRefreshIcon(spinning: spinning)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .disabled(gateway.working || spinning || gateway.reconnecting)
        .help("Recheck Secure Access").accessibilityLabel("Recheck Secure Access")
    }

    private var secureAccessMenu: some View {
        Menu {
            if gateway.status?.sharedMigrationAvailable == true || gateway.status?.endpointMigrationPending == true {
                Button(gateway.status?.endpointMigrationPending == true ? "Retry Shared Secure Access Migration…" : "Use Shared Secure Access…") { confirmSharedMigration = true }
                    .disabled(gateway.working)
            }
            if secureAccess.canSignOut {
                Button("Sign Out of Tailscale…") { confirmTunnelLogout = true }
                    .disabled(gateway.working || gateway.status?.gatewayID == nil)
            }
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Secure Access actions")
    }

    private func handleSecureAccess(_ action: SecureAccessPresentation.Action) async {
        if let migration = SecureAccessPresentation.migrationAction(for: action, isSideGate: context.isSide,
                                                                    pending: gateway.status?.endpointMigrationPending == true) {
            if !(await gateway.perform(migration)) { setupNotice = gateway.message }
            return
        }
        switch action {
        case .setUp:
            _ = await gateway.perform("prepare-access")
        case .signIn:
            guard await gateway.perform("prepare-access") else {
                setupNotice = gateway.message ?? "未能準備登入，請稍後再試。"
                return
            }
            if !(await gateway.signInTunnel()) {
                setupNotice = gateway.message ?? "未能開啟登入頁面，請稍後再試。"
            }
        case .approve:
            let approvalURL = secureAccess.approvalURL
            guard await gateway.perform("prepare-access") else { return }
            if let url = secureAccess.approvalURL ?? approvalURL { NSWorkspace.shared.open(url) }
        case .repair:
            if gateway.status?.localOnly == true { _ = await gateway.perform("prepare-access") }
            else { await gateway.repair() }
        case .repairDNS:
            confirmDNSRepair = true
        case .recheck:
            await gateway.refresh()
        }
    }

    private func openTailscale() {
        for id in ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init()); return
            }
        }
    }

    private func toggleDetails() {
        let expand = !detailsExpanded
        if !expand { setupExpanded = false }
        expandedOverride = expand
    }

    private func reconcileSetup() {
        guard gateway.statusConfirmed else { return }
        // Record an actual successful authorization once, including authorizations created before this UI version.
        if !context.isSide { setup.observeAuthorization(gateID: gateway.status?.gatewayID, connections: gateway.status?.aiConnections) }
        setup.reconcile(gateID: gateway.status?.gatewayID, connections: gateway.status?.aiConnections,
                        pairingActive: gateway.status?.pairingActive)
    }

    private var aiConnectionRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !journey.aiConnections.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(journey.aiConnections) { connection in
                            HStack(spacing: 8) {
                                GateJourneyDot(state: connection.isAuthorized ? .completed : connection.needsAttention ? .attention : .pending,
                                               pulses: false, completedColor: .blue)
                                    .frame(width: 16, height: 24)
                                Text(connection.name).font(.callout).lineLimit(1).help(connection.name)
                                Text(connection.statusLabel).font(.caption)
                                    .foregroundStyle(connection.needsAttention ? Color.orange : Color.secondary)
                                    .help(connection.reason ?? "Authorization status is unknown.")
                                Spacer(minLength: 8)
                                Menu {
                                    Button("Connection Details…") { detailConnectionID = connection.id }
                                    if connection.isAuthorized {
                                        Button("Revoke and Remove…", role: .destructive) { revokeConnection = connection }
                                            .disabled(gateway.working || gateway.status?.clientRevocationVersion != 1)
                                    }
                                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("Connection actions")
                                .popover(isPresented: Binding(
                                    get: { detailConnectionID == connection.id },
                                    set: { if !$0 && detailConnectionID == connection.id { detailConnectionID = nil } }
                                ), arrowEdge: .trailing) {
                                    connectionDetails(connection)
                                }
                                if !connection.isAuthorized {
                                    Button(connection.needsAttention ? "Fix" : "Set Up") { beginAISetup(connection) }
                                        .controlSize(.small)
                                        .disabled(!gateway.usable || gateway.working || gateway.visiblyChecking)
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
                            .help("Client: \(connection.clientID)")
                        }
                    }
                }
                .frame(height: min(180, CGFloat(journey.aiConnections.count) * 32))
            }
        }
    }

    private func connectionDetails(_ connection: GatewayAIConnection) -> some View {
        let serverURL = gateway.status?.mcpURL ?? gateway.status?.stableMCPURL
        return VStack(alignment: .leading, spacing: 14) {
            Text("Connection Details").font(.headline)
            Text(connection.name).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    Text(serverURL ?? "Available when Secure Access is ready.")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { if let serverURL { gateway.copy(serverURL) } } label: {
                        Image(systemName: "doc.on.doc").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Copy Server URL").accessibilityLabel("Copy Server URL")
                    .disabled(serverURL == nil)
                }
            }
        }
        .padding(18).frame(width: 420)
    }

    @ViewBuilder
    private var journeyAction: some View {
        if journey.activeStage == .local {
            Button(journey.nodes[0] == .attention ? "Repair" : "Open Gate") {
                Task { await runPrimaryAction() }
            }.buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(gateway.working || gateway.visiblyChecking || gateway.reconnecting)
        } else if journey.activeStage == .ready && !journey.isReady {
            Button("Recheck") { Task { await gateway.refresh() } }.disabled(gateway.working || gateway.visiblyChecking)
        } else if journey.activeStage == .aiConnection && gateway.status?.aiConnections == nil {
            Button("Recheck") { Task { await gateway.refresh() } }.disabled(gateway.working || gateway.visiblyChecking)
        }
    }

    private func beginAISetup(_ connection: GatewayAIConnection? = nil) {
        expandedOverride = true
        setupExpanded = true
        if let connection, setup.draft?.inProgress != true, let id = gateway.status?.gatewayID {
            let app: AISetupDraft.App = connection.name.localizedCaseInsensitiveContains("ChatGPT") ? .chatGPT
                : connection.name.localizedCaseInsensitiveContains("Claude") ? .claude : .other
            _ = setup.begin(app, gateID: id)
        }
    }

    private var advancedConnectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if gateway.statusConfirmed && (gateway.status?.running == true || gateway.status?.desiredRunning == true) {
                    if gateway.status?.running == true && gateway.status?.state != "unknown" {
                        Button("Restart") { Task { await gateway.restart() } }
                            .disabled(gateway.working || gateway.visiblyChecking || changed)
                    }
                    Button("Close Gate") { Task { _ = await gateway.perform("stop") } }
                        .disabled(gateway.working)
                }
                Button("Recheck") { Task { await gateway.refresh() } }
                    .disabled(gateway.working || gateway.visiblyChecking)
            }
            .controlSize(.small)
            Toggle("斷線後自動恢復", isOn: Binding(
                get: { gateway.automaticallyReconnects },
                set: { enabled in Task { await gateway.setAutomaticReconnect(enabled) } }
            ))
            .toggleStyle(.checkbox)
            .disabled(gateway.working || !gateway.statusConfirmed )
            .help("App 運行時自動恢復已開啟嘅Gate；手動停止後唔會自行開啟。")
            if gateway.status?.transport != "cloudflare" {
                Button("Advanced Tunnel Details…") { showTunnelManagement = true }
            }
            DisclosureGroup("MCP authorization management") {
                Button("Revoke all \(context.title) authorizations…", role: .destructive) { confirmRevoke = true }
                    .disabled(gateway.working)
            }
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
                    .disabled(gateway.working || gateway.visiblyChecking || changed)
                    .help("重啟此 Gate，保留原有 MCP 授權同固定地址。")
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
            if journey.activeStage == .local {
                _ = await gateway.perform("start-local")
            } else { await gateway.repair() }
            expandedOverride = true
        case .ready:
            beginAISetup()
        }
    }

}

private struct SecureAccessRefreshIcon: View {
    let spinning: Bool
    @State private var rotation = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 12, weight: .medium))
            .rotationEffect(.degrees(rotation))
            .frame(width: 24, height: 24)
            .onChange(of: spinning, initial: true) { _, _ in updateRotation() }
            .onChange(of: reduceMotion) { _, _ in updateRotation() }
    }

    private func updateRotation() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { rotation = 0 }
        if spinning && !reduceMotion {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
