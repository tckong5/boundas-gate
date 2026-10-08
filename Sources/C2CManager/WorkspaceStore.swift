import AppKit
import CryptoKit
import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    let gateway: SharedGatewayStore
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    @Published private(set) var statuses: [UUID: WorkspaceStatus] = [:]
    @Published private(set) var busy: [UUID: WorkspaceOperation] = [:]
    @Published private(set) var pairingCodes: [UUID: PairingCode] = [:]
    @Published private(set) var diagnostics: [UUID: ConnectionDiagnostics] = [:]
    @Published private(set) var checkingConnections: Set<UUID> = []
    @Published var selectedID: UUID? = SharedGatewayStore.selectionID
    @Published var alertMessage: String?
    @Published var showingAddPath = false
    @Published var guidedWorkspaceID: UUID?
    @Published var stableWorkspaceID: UUID?

    private let client: any SideGateClient
    private let checker = ConnectionChecker()
    private var checkTasks: [UUID: Task<ConnectionDiagnostics, Never>] = [:]
    private var checkTokens: [UUID: UUID] = [:]
    private var revisions: [UUID: Int] = [:]
    private let configURL: URL
    private let c2cLogDirectory: URL

    var runningCount: Int { sideGateWorkspaces.filter { statuses[$0.id]?.running == true }.count }
    var healthyConnectionCount: Int { sideGateWorkspaces.filter { $0.canOperateSideGate && diagnostics[$0.id]?.isUsable == true }.count }
    var sideGateWorkspaces: [WorkspaceRecord] { workspaces.filter(\.belongsToSideGates) }

    init(configURL: URL? = nil, client: (any SideGateClient)? = nil,
         gateway: SharedGatewayStore? = nil, automaticallyRefresh: Bool = true) {
        self.configURL = configURL ?? AppDataPaths.current.workspaces
        self.client = client ?? C2CClient()
        self.gateway = gateway ?? SharedGatewayStore(automaticallyRefresh: automaticallyRefresh)
        c2cLogDirectory = AppDataPaths.current.c2cLogs
        load()
        guard automaticallyRefresh else { return }
        Task { [weak self] in
            while let self {
                await self.refreshAll()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "加入資料夾（可多選）"
        panel.message = "按住 ⌘ 選多個資料夾；連續項目可用 Shift。"
        panel.prompt = "加入所選資料夾"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            _ = addPath(url.path)
        }
    }

    @discardableResult
    func addPath(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard !trimmed.isEmpty, expanded.hasPrefix("/") else {
            alertMessage = "請輸入以 / 或 ~/ 開頭嘅 folder 路徑。"
            return false
        }
        let canonical = URL(fileURLWithPath: expanded, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            alertMessage = "搵唔到呢個 folder：\(trimmed)"
            return false
        }
        if let existing = workspaces.first(where: { $0.path == canonical.path }) {
            if selectedID != SharedGatewayStore.selectionID {
                guard existing.sideGateRemovalState == nil else {
                    alertMessage = "請先 Retry 完成 Remove Side Gate，再重新加入。"
                    return false
                }
                if let index = workspaces.firstIndex(where: { $0.id == existing.id }) {
                    workspaces[index].sideGateAdded = true
                    save()
                }
                selectedID = existing.id
            }
            return true
        }

        let digest = SHA256.hash(data: Data(canonical.path.lowercased().utf8))
        let c2cID = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        let folderName = canonical.lastPathComponent
        let displayName = workspaces.contains(where: { $0.name == folderName })
            ? "\(folderName) · \(canonical.deletingLastPathComponent().lastPathComponent)"
            : folderName
        var record = WorkspaceRecord(name: displayName, path: canonical.path, c2cID: String(c2cID))
        record.sideGateAdded = selectedID != SharedGatewayStore.selectionID
        workspaces.append(record)
        if selectedID != SharedGatewayStore.selectionID { selectedID = record.id }
        save()
        Task { await refresh(record) }
        return true
    }

    func rename(_ workspace: WorkspaceRecord, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspaces[index].name = trimmed
        save()
    }

    func refreshAll() async {
        pairingCodes = pairingCodes.filter { $0.value.expiresAt > Date() }
        for workspace in sideGateWorkspaces where workspace.canOperateSideGate && busy[workspace.id] == nil {
            await refresh(workspace)
        }
    }

    func refresh(_ workspace: WorkspaceRecord, forceConnectionCheck: Bool = false) async {
        guard let workspace = operableSideGate(workspace) else { return }
        guard FileManager.default.fileExists(atPath: workspace.path) else {
            invalidateConnection(workspace)
            statuses[workspace.id] = nil
            return
        }
        let revision = revisions[workspace.id, default: 0]
        do {
            let status = try await client.status(for: workspace)
            guard revisions[workspace.id, default: 0] == revision,
                  operableSideGate(workspace) != nil else { return }
            let previous = statuses[workspace.id]
            let changed = previous?.port != status.port || previous?.pid != status.pid
                || previous?.running != status.running || previous?.mcpURL != status.mcpURL
                || previous?.tunnel?.running != status.tunnel?.running
            if changed { invalidateConnection(workspace) }
            statuses[workspace.id] = status
            if status.pairingActive == false { pairingCodes[workspace.id] = nil }
            if let url = status.mcpURL, let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                let oldURL = workspaces[index].lastObservedMCPURL
                workspaces[index].observeMCPURL(url)
                if oldURL != workspaces[index].lastObservedMCPURL { save() }
            }
            let expired = diagnostics[workspace.id].map { Date().timeIntervalSince($0.checkedAt) >= 30 } ?? true
            if forceConnectionCheck || changed || expired {
                await checkConnection(workspace, status: status, force: forceConnectionCheck || changed)
            }
        } catch {
            guard revisions[workspace.id, default: 0] == revision else { return }
            invalidateConnection(workspace)
            statuses[workspace.id] = WorkspaceStatus(running: nil, state: "unknown", reason: error.localizedDescription, port: nil, pid: nil, publicUrl: nil, tunnel: nil, tokenCount: nil, pairingActive: nil)
        }
    }

    private func invalidateConnection(_ workspace: WorkspaceRecord) {
        revisions[workspace.id, default: 0] += 1
        checkTasks.removeValue(forKey: workspace.id)?.cancel()
        checkTokens[workspace.id] = nil
        checkingConnections.remove(workspace.id)
        diagnostics[workspace.id] = nil
    }

    private func checkConnection(_ workspace: WorkspaceRecord, status: WorkspaceStatus, force: Bool) async {
        guard operableSideGate(workspace) != nil else { return }
        if checkTasks[workspace.id] != nil && !force { return }
        checkTasks[workspace.id]?.cancel()
        let token = UUID()
        let revision = revisions[workspace.id, default: 0]
        let checker = checker
        let task = Task { await checker.check(workspaceID: workspace.c2cID, status: status) }
        checkTasks[workspace.id] = task
        checkTokens[workspace.id] = token
        checkingConnections.insert(workspace.id)
        let result = await task.value
        guard checkTokens[workspace.id] == token, revisions[workspace.id, default: 0] == revision else { return }
        checkTasks[workspace.id] = nil
        checkTokens[workspace.id] = nil
        checkingConnections.remove(workspace.id)
        diagnostics[workspace.id] = result
    }

    func diagnoseConnection(_ workspace: WorkspaceRecord) async {
        guard operableSideGate(workspace) != nil, busy[workspace.id] == nil else { return }
        busy[workspace.id] = .diagnose
        defer { busy[workspace.id] = nil }
        invalidateConnection(workspace)
        await refresh(workspace, forceConnectionCheck: true)
    }

    func setConnectorURL(_ workspace: WorkspaceRecord, to value: String) {
        guard operableSideGate(workspace) != nil else { return }
        guard let normalized = EndpointAddress.mcpURL(value), normalized.hasPrefix("https://") else {
            alertMessage = "請貼上 ChatGPT connector 入面嘅 HTTPS Server URL（/mcp）。"
            return
        }
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].configuredMCPURL = normalized
        save()
    }

    func confirmConnectorUpdated(_ workspace: WorkspaceRecord) {
        guard diagnostics[workspace.id]?.isUsable == true, let url = statuses[workspace.id]?.mcpURL else { return }
        setConnectorURL(workspace, to: url)
    }

    func start(_ workspace: WorkspaceRecord, reportErrors: Bool = true) async {
        guard let workspace = operableSideGate(workspace) else { return }
        guard busy[workspace.id] == nil else { return }
        busy[workspace.id] = .start
        invalidateConnection(workspace)
        defer { busy[workspace.id] = nil }
        do {
            let result = try await client.start(workspace)
            await refresh(workspace, forceConnectionCheck: true)
            if result.mcpUrl != nil && diagnostics[workspace.id]?.isUsable == true && statuses[workspace.id]?.tokenCount == 0 {
                do {
                    pairingCodes[workspace.id] = try await client.pair(workspace)
                    await refresh(workspace)
                } catch {
                    if reportErrors { alertMessage = "\(workspace.name) 已啟動，但未能產生配對碼。請喺連線引導再試一次。" }
                }
            }
        } catch {
            await refresh(workspace)
            if reportErrors { alertMessage = "\(workspace.name) 連線未能開啟。請用「幫我修復連線」引導重試。" }
        }
    }

    func stop(_ workspace: WorkspaceRecord) async {
        guard let workspace = operableSideGate(workspace), busy[workspace.id] == nil else { return }
        busy[workspace.id] = .stop
        invalidateConnection(workspace)
        defer { busy[workspace.id] = nil }
        do {
            try await client.stop(workspace)
            pairingCodes[workspace.id] = nil
            await refresh(workspace)
        } catch {
            await refresh(workspace)
            alertMessage = "\(workspace.name)：\(error.localizedDescription)"
        }
    }

    func restart(_ workspace: WorkspaceRecord, reportErrors: Bool = true) async {
        guard let workspace = operableSideGate(workspace) else { return }
        guard busy[workspace.id] == nil else { return }
        busy[workspace.id] = .restart
        invalidateConnection(workspace)
        defer { busy[workspace.id] = nil }
        do {
            try await client.stop(workspace)
            try await waitForStop(workspace)
            pairingCodes[workspace.id] = nil
            let result = try await client.start(workspace)
            await refresh(workspace, forceConnectionCheck: true)
            if result.mcpUrl != nil && diagnostics[workspace.id]?.isUsable == true && statuses[workspace.id]?.tokenCount == 0 {
                do {
                    pairingCodes[workspace.id] = try await client.pair(workspace)
                    await refresh(workspace)
                } catch {
                    if reportErrors { alertMessage = "\(workspace.name) 已重新啟動，但未能產生配對碼。請喺連線引導再試一次。" }
                }
            }
        } catch {
            await refresh(workspace)
            if reportErrors { alertMessage = "\(workspace.name) 連線未能修復。請喺修復引導重新檢查，或複製求助資料。" }
        }
    }

    private func waitForStop(_ workspace: WorkspaceRecord) async throws {
        for _ in 0..<40 {
            if try await client.status(for: workspace).running == false { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw C2CClientError.commandFailed("現有連線未完全停止，請稍後再試。")
    }

    func enableStableConnection(_ workspace: WorkspaceRecord) async -> String? {
        guard busy[workspace.id] == nil,
              operableSideGate(workspace) != nil else { return "Side Gate 未啟用，或者正在移除。" }
        busy[workspace.id] = .restart
        invalidateConnection(workspace)
        defer { busy[workspace.id] = nil }
        do {
            let setup = try await client.tailscaleSetup()
            guard setup.ready else { return setup.message }
            try await client.stop(workspace)
            try await waitForStop(workspace)
            guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return "Folder 已移除。" }
            workspaces[index].connectionProvider = .tailscale
            let updatedWorkspace = workspaces[index]
            save()
            pairingCodes[workspace.id] = nil
            _ = try await client.start(updatedWorkspace)
            await refresh(updatedWorkspace, forceConnectionCheck: true)
            for _ in 0..<3 where diagnostics[workspace.id]?.isUsable != true {
                try await Task.sleep(for: .seconds(3))
                await refresh(updatedWorkspace, forceConnectionCheck: true)
            }
            guard diagnostics[workspace.id]?.isUsable == true else {
                return "固定地址已設定，但公開連線未通過檢查。請確認 Tailscale 已連線，再用修復引導重試。"
            }
            return nil
        } catch {
            await refresh(workspace)
            return error.localizedDescription
        }
    }

    func openTailscale() {
        let url = URL(fileURLWithPath: "/Applications/Tailscale.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func repairConnection(_ workspace: WorkspaceRecord) async -> Bool {
        guard operableSideGate(workspace) != nil, busy[workspace.id] == nil else { return false }
        if statuses[workspace.id]?.running == true {
            await restart(workspace, reportErrors: false)
        } else {
            await start(workspace, reportErrors: false)
        }
        // A newly created tunnel can need a few seconds before its address responds.
        for _ in 0..<3 where diagnostics[workspace.id]?.isUsable != true && statuses[workspace.id]?.running == true {
            do { try await Task.sleep(for: .seconds(3)) } catch { return false }
            await diagnoseConnection(workspace)
        }
        return diagnostics[workspace.id]?.isUsable == true
    }

    func generatePairingCode(_ workspace: WorkspaceRecord) async {
        guard operableSideGate(workspace) != nil, busy[workspace.id] == nil else { return }
        busy[workspace.id] = .pair
        defer { busy[workspace.id] = nil }
        do {
            await refresh(workspace, forceConnectionCheck: true)
            guard diagnostics[workspace.id]?.isUsable == true else {
                alertMessage = "請先檢查或重建 \(workspace.name) 嘅公開連線，再產生配對碼。"
                return
            }
            pairingCodes[workspace.id] = try await client.pair(workspace)
            await refresh(workspace)
        } catch {
            alertMessage = "\(workspace.name)：\(error.localizedDescription)"
        }
    }

    func startAll() async {
        for workspace in sideGateWorkspaces where workspace.canOperateSideGate && statuses[workspace.id]?.running != true {
            await start(workspace)
        }
    }

    func stopAll() async {
        for workspace in sideGateWorkspaces where workspace.canOperateSideGate && statuses[workspace.id]?.running == true {
            await stop(workspace)
        }
    }

    func reconnectAll() async {
        for workspace in sideGateWorkspaces where workspace.canOperateSideGate {
            _ = await repairConnection(workspace)
        }
    }

    private func operableSideGate(_ workspace: WorkspaceRecord) -> WorkspaceRecord? {
        workspaces.first { $0.id == workspace.id && $0.canOperateSideGate }
    }

    func removeFolder(_ workspace: WorkspaceRecord) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        guard !workspaces[index].belongsToSideGates else {
            alertMessage = "請先 Remove Side Gate，再移除 Folder。"
            return
        }
        let original = workspaces
        workspaces.remove(at: index)
        guard save() else { workspaces = original; return }
        // Main Gate checks the live Folder registry on every access; the endpoint stays open.
        Task { await gateway.refresh() }
    }

    func removeSideGate(_ workspace: WorkspaceRecord) async {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id && $0.belongsToSideGates }),
              busy[workspace.id] == nil else { return }
        let original = workspaces[index]
        workspaces[index].sideGateRemovalState = .removing
        workspaces[index].sideGateRemovalError = nil
        guard save() else { workspaces[index] = original; return }
        busy[workspace.id] = .remove
        defer { busy[workspace.id] = nil }
        invalidateConnection(workspace)
        do {
            try await client.decommission(workspaces[index])
            guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
            workspaces[index].sideGateAdded = false
            workspaces[index].sideGateRemovalState = nil
            workspaces[index].sideGateRemovalError = nil
            workspaces[index].lastKnownMCPURL = original.lastObservedMCPURL ?? original.configuredMCPURL ?? original.lastKnownMCPURL
            workspaces[index].lastObservedMCPURL = nil
            workspaces[index].previousMCPURL = nil
            workspaces[index].configuredMCPURL = nil
            guard save() else { throw C2CClientError.commandFailed("未能儲存 Side Gate 移除結果。") }
        } catch {
            guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
            workspaces[index].sideGateAdded = true
            workspaces[index].lastObservedMCPURL = original.lastObservedMCPURL
            workspaces[index].previousMCPURL = original.previousMCPURL
            workspaces[index].configuredMCPURL = original.configuredMCPURL
            workspaces[index].lastKnownMCPURL = original.lastKnownMCPURL
            workspaces[index].sideGateRemovalState = .failed
            workspaces[index].sideGateRemovalError = error.localizedDescription
            save()
            alertMessage = "Remove Side Gate 未完成，可以 Retry：\(error.localizedDescription)"
            return
        }
        statuses[workspace.id] = nil
        diagnostics[workspace.id] = nil
        pairingCodes[workspace.id] = nil
        if selectedID == workspace.id { selectedID = nil }
    }

    func copyURL(_ workspace: WorkspaceRecord) {
        guard operableSideGate(workspace) != nil, diagnostics[workspace.id]?.isUsable == true,
              let url = statuses[workspace.id]?.mcpURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copySupportReport(_ workspace: WorkspaceRecord) {
        copyText(ConnectionSupportReport.make(workspace: workspace, status: statuses[workspace.id], diagnostics: diagnostics[workspace.id]))
    }

    func copyPairingCode(_ workspace: WorkspaceRecord) {
        guard operableSideGate(workspace) != nil, let pairing = pairingCodes[workspace.id], pairing.expiresAt > Date() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairing.value, forType: .string)
    }

    func openFolder(_ workspace: WorkspaceRecord) {
        NSWorkspace.shared.open(URL(fileURLWithPath: workspace.path))
    }

    func openLogs(_ workspace: WorkspaceRecord) {
        let file = c2cLogDirectory.appendingPathComponent("bridge-\(workspace.c2cID).out.log")
        let target = FileManager.default.fileExists(atPath: file.path) ? file : c2cLogDirectory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func openChatGPT() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/plugins")!)
    }

    private func load() {
        guard let data = try? Data(contentsOf: configURL),
              let saved = try? JSONDecoder().decode([WorkspaceRecord].self, from: data) else { return }
        workspaces = saved.map { record in
            var record = record
            if record.sideGateAdded == nil {
                record.sideGateAdded = record.lastObservedMCPURL != nil || record.configuredMCPURL != nil
            }
            if record.sideGateRemovalState == .removing {
                record.sideGateRemovalState = .failed
                record.sideGateRemovalError = "上次移除未完成，請 Retry。"
            }
            return record
        }
        if workspaces != saved { save() }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            let directory = configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(workspaces)
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            return true
        } catch {
            alertMessage = "無法儲存 Folders：\(error.localizedDescription)"
            return false
        }
    }
}
