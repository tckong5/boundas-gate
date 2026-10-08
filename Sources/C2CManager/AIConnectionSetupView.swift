import SwiftUI

struct AIConnectionSetupView: View {
    @ObservedObject var gateway: SharedGatewayStore
    @ObservedObject var setup: AISetupStore
    @Binding var expanded: Bool
    var context: GateUIContext = .main
    @State private var choosingApp = false
    @State private var reviewingConfiguration = false
    @State private var notice: String?

    private var busy: Bool { gateway.working || gateway.visiblyChecking }
    private var hasAuthorization: Bool { gateway.status?.aiConnections?.contains(where: \.isAuthorized) == true }
    private var serverURL: String? { gateway.status?.mcpURL ?? gateway.status?.stableMCPURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let draft = setup.draft, draft.inProgress {
                if expanded {
                    if draft.stage == .configureClient || reviewingConfiguration { configuration(draft.app) }
                    else { authorization(draft) }
                } else {
                    Button("Continue Setup") { expanded = true }.controlSize(.small)
                        .padding(.trailing, 36)
                }
            } else if choosingApp || !hasAuthorization {
                Text("Which app do you want to connect?").font(.callout)
                HStack(spacing: 8) {
                    ForEach(AISetupDraft.App.allCases, id: \.self) { app in
                        Button(app.title) {
                            guard let id = gateway.status?.gatewayID else { return }
                            if setup.begin(app, gateID: id) { expanded = true; choosingApp = false; notice = nil }
                        }.disabled(busy || !gateway.usable)
                    }
                }
                if hasAuthorization {
                    Button("Back to authorized apps") { choosingApp = false }.buttonStyle(.borderless)
                }
            } else {
                Button("Add Another App") { choosingApp = true; expanded = true }
                    .controlSize(.small).disabled(busy || !gateway.usable)
            }
            if let message = notice ?? setup.error {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if let draft = setup.draft, draft.inProgress {
                Menu {
                    if draft.stage == .authorize, let serverURL {
                        Button("Copy Server URL") { gateway.copy(serverURL) }
                    }
                    Button("Cancel Setup") { Task { await cancel() } }.disabled(busy)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Setup actions")
            }
        }
        .onAppear {
            if expanded && setup.draft?.inProgress != true && hasAuthorization { choosingApp = true }
        }
        .onChange(of: setup.draft?.stage) { _, stage in
            if stage == .completed { expanded = false; choosingApp = false; reviewingConfiguration = false; notice = nil }
        }
        .onChange(of: setup.draft?.id) { _, _ in reviewingConfiguration = false }
        .onChange(of: expanded) { _, value in
            if value && setup.draft?.inProgress != true { choosingApp = true }
        }
    }

    private func configuration(_ app: AISetupDraft.App) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(configurationIntro(app)).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 36)
            numberedInstructions(configurationInstructions(app))
            VStack(alignment: .leading, spacing: 18) {
                configurationField("Name", value: context.appName)
                configurationField("Description", value: context.appDescription)
                configurationField("Server URL", value: serverURL)
            }
            .padding(.top, 4)
            HStack {
                Spacer()
                Button("Continue") {
                    if reviewingConfiguration { reviewingConfiguration = false }
                    else { setup.authorize() }
                }
                    .buttonStyle(.borderedProminent).disabled(busy || !gateway.usable)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configurationField(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                Text(value ?? "Available when Secure Access is ready.")
                    .font(title == "Server URL" ? .system(.callout, design: .monospaced) : .callout)
                    .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { if let value { gateway.copy(value) } } label: {
                    Image(systemName: "doc.on.doc").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Copy \(title)").accessibilityLabel("Copy \(title)")
                .disabled(value == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func authorization(_ draft: AISetupDraft) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Authorize \(draft.app == .other ? "your AI app" : draft.app.title) to use this Gate.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 36)
            numberedInstructions([
                draft.app == .claude ? "Choose sign-in authentication and automatic client registration" : "Choose OAuth when prompted",
                "Open the Boundas Gate authorization page",
                "Generate a pairing code below, then enter it to connect"
            ])
            if let pairing = gateway.pairing, let id = pairing.sessionID, draft.pairingSessionIDs.contains(id) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(ceil(pairing.expiration.timeIntervalSince(context.date))))
                    if remaining > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pairing Code").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(pairing.pairingCode).font(.system(.title2, design: .monospaced).weight(.semibold))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button { gateway.copy(pairing.pairingCode) } label: {
                                    Image(systemName: "doc.on.doc").frame(width: 24, height: 24)
                                }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Copy Pairing Code").accessibilityLabel("Copy Pairing Code")
                            }
                            Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else { Text("Pairing code expired.").font(.caption).foregroundStyle(.secondary) }
                }
            } else if !draft.pairingSessionIDs.isEmpty {
                Text(gateway.status?.pairingActive == true
                     ? "This code can't be displayed after reopening the app. Generate a new code if you still need one."
                     : "Pairing code is no longer available. Generate a new code if authorization hasn't finished.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !draft.pairingSessionIDs.isEmpty {
                HStack(spacing: 6) {
                    GateJourneyDot(state: .current)
                    Text("Waiting for \(draft.app == .other ? "your AI app" : draft.app.title)…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if gateway.status?.setupManagementVersion != 1 {
                Text("Restart Gate once to enable resumable setup. Existing authorizations are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    reviewingConfiguration = true
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Review app setup details")
                Spacer()
                if gateway.status?.setupManagementVersion != 1 {
                    Button("Restart Gate") { Task { await gateway.restart() } }.disabled(busy)
                } else {
                    Button(draft.pairingSessionIDs.isEmpty ? "Generate Pairing Code" : "Generate New Code") {
                        Task {
                            guard draft.pairingSessionIDs.count < 128 else {
                                notice = "Cancel this unfinished setup before starting a new attempt."; return
                            }
                            if await gateway.perform("pair"), let pairing = gateway.pairing {
                                setup.attach(pairing)
                                reconcile()
                            } else { notice = gateway.userFacingMessage ?? "The code couldn't be generated. Please try again." }
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(busy || !gateway.usable)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberedInstructions(_ instructions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "\(index + 1).circle")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(instruction).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func reconcile() {
        setup.reconcile(gateID: gateway.status?.gatewayID, connections: gateway.status?.aiConnections,
                        pairingActive: gateway.status?.pairingActive)
    }

    private func cancel() async {
        await gateway.refresh()
        reconcile()
        guard let draft = setup.draft, draft.inProgress else { return }
        if !draft.pairingSessionIDs.isEmpty {
            guard await gateway.perform("cancel-setup", sessionIDs: draft.pairingSessionIDs) else {
                reconcile()
                notice = "Setup couldn't be cancelled. Recheck and try again; an app may have just become authorized."
                return
            }
        }
        if setup.clear() { expanded = false; choosingApp = false; notice = nil }
    }

    private func configurationIntro(_ app: AISetupDraft.App) -> String {
        switch app {
        case .chatGPT: return "Create an MCP app in ChatGPT."
        case .claude: return "Create a custom connector in Claude."
        case .other: return "Create an MCP connection in your AI app."
        }
    }

    private func configurationInstructions(_ app: AISetupDraft.App) -> [String] {
        switch app {
        case .chatGPT: return ["Open Plugins", "Click Add +", "Choose Create MCP App"]
        case .claude: return ["Open Customize, then Connectors", "Click Add +", "Choose Add custom connector"]
        case .other: return ["Open your AI app’s MCP connection settings", "Add a custom MCP connection", "Enter the details below"]
        }
    }
}
