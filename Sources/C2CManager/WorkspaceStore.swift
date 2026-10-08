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

    private let client: any SideGateClient
    private let checker = ConnectionChecker()
    private var sideGateConnections: [UUID: SharedGatewayStore] = [:]
    private var checkTasks: [UUID: Task<ConnectionDiagnostics, Never>] = [:]
    private var checkTokens: [UUID: UUID] = [:]
    private var revisions: [UUID: Int] = [:]
    private let configURL: URL
    private let c2cLogDirectory: URL

    var runningCount: Int { sideGateWorkspaces.filter { statuses[$0.id]?.running == true }.count }
    var healthyConnectionCount: Int { sideGateWorkspaces.filter { $0.canOperateSideGate && diagnostics[$0.id]?.isUsable == true }.count }
    var mainGateWorkspaces: [WorkspaceRecord] { orderedFolders(side: false) }
    var sideGateWorkspaces: [WorkspaceRecord] { orderedFolders(side: true) }

    private func orderedFolders(side: Bool) -> [WorkspaceRecord] {
        workspaces.enumerated()
            .filter { side ? $0.element.belongsToSideGates : $0.element.belongsToMainGate }
            .sorted {
                let lhs = (side ? $0.element.sideGateOrder : $0.element.mainGateOrder) ?? $0.offset
                let rhs = (side ? $1.element.sideGateOrder : $1.element.mainGateOrder) ?? $1.offset
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }
            .map(\.element)
    }

    func moveFolders(from offsets: IndexSet, to destination: Int, side: Bool) {
        var folders = side ? sideGateWorkspaces : mainGateWorkspaces
        guard !offsets.isEmpty, offsets.allSatisfy({ folders.indices.contains($0) }),
              (0...folders.count).contains(destination) else { return }
        let moving = offsets.sorted().map { folders[$0] }
        for index in offsets.sorted(by: >) { folders.remove(at: index) }
        folders.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        let original = workspaces
        for (order, folder) in folders.enumerated() {
            guard let index = workspaces.firstIndex(where: { $0.id == folder.id }) else { continue }
            if side { workspaces[index].sideGateOrder = order }
            else { workspaces[index].mainGateOrder = order }
        }
        if !save() { workspaces = original }
    }

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
                await self.refreshSideGateJourneys()
                await self.refreshAll()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    // One observation/reconnect policy per Gate, shared with its detail view.
    // Monitoring runs even when the user is looking at Main Gate.
    func sideGateway(for workspace: WorkspaceRecord) -> SharedGatewayStore {
        if let existing = sideGateConnections[workspace.id] { return existing }
        let gateway = SharedGatewayStore(automaticallyRefresh: false, gateSourceID: workspace.id.uuidString.lowercased())
        sideGateConnections[workspace.id] = gateway
        return gateway
    }

    private func refreshSideGateJourneys() async {
        for workspace in sideGateWorkspaces where workspace.canOperateSideGate && busy[workspace.id] == nil {
            let connection = sideGateway(for: workspace)
            guard !connection.working else { continue }
            await connection.refresh(background: true)
            guard operableSideGate(workspace) != nil, busy[workspace.id] == nil else { continue }
            await connection.recoverIfNeeded()
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
        // Match the Gateway's filesystem realpath, including macOS /private aliases.
        // URL standardization can shorten /private/tmp back to /tmp after resolution.
        guard let resolved = realpath(expanded, nil) else {
            alertMessage = "搵唔到呢個 folder：\(trimmed)"
            return false
        }
        let canonicalPath = String(cString: resolved)
        free(resolved)
        let canonical = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            alertMessage = "搵唔到呢個 folder：\(trimmed)"
            return false
        }
        if let existing = workspaces.first(where: { $0.path == canonicalPath }) {
            if selectedID != SharedGatewayStore.selectionID {
                guard existing.sideGateRemovalState == nil else {
                    alertMessage = "請先 Retry 完成 Remove Side Gate，再重新加入。"
                    return false
                }
                if let index = workspaces.firstIndex(where: { $0.id == existing.id }) {
                    let original = workspaces[index]
                    if !existing.belongsToSideGates { workspaces[index].sideGateOrder = nextFolderOrder(side: true) }
                    workspaces[index].sideGateAdded = true
                    guard save() else { workspaces[index] = original; return false }
                }
                selectedID = existing.id
            } else if let index = workspaces.firstIndex(where: { $0.id == existing.id }), !existing.belongsToMainGate {
                let original = workspaces[index]
                workspaces[index].mainGateOrder = nextFolderOrder(side: false)
                workspaces[index].mainGateAdded = true
                guard save() else { workspaces[index] = original; return false }
            }
            return true
        }

        let digest = SHA256.hash(data: Data(canonicalPath.lowercased().utf8))
        let c2cID = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        let folderName = canonical.lastPathComponent
        let displayName = workspaces.contains(where: { $0.name == folderName })
            ? "\(folderName) · \(canonical.deletingLastPathComponent().lastPathComponent)"
            : folderName
        var record = WorkspaceRecord(name: displayName, path: canonicalPath, c2cID: String(c2cID))
        let side = selectedID != SharedGatewayStore.selectionID
        record.mainGateAdded = !side
        record.sideGateAdded = side
        if side { record.sideGateOrder = nextFolderOrder(side: true) }
        else { record.mainGateOrder = nextFolderOrder(side: false) }
        workspaces.append(record)
        guard save() else { workspaces.removeLast(); return false }
        if side { selectedID = record.id }
        Task { await refresh(record) }
        return true
    }

    private func nextFolderOrder(side: Bool) -> Int {
        let orders = workspaces.enumerated()
            .filter { side ? $0.element.belongsToSideGates : $0.element.belongsToMainGate }
            .map { (side ? $0.element.sideGateOrder : $0.element.mainGateOrder) ?? $0.offset }
        return (orders.max() ?? -1) + 1
    }

    @discardableResult
    func addToSideGates(_ workspace: WorkspaceRecord) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }),
              workspaces[index].sideGateRemovalState == nil, busy[workspace.id] == nil else { return false }
        guard !workspaces[index].belongsToSideGates else { return true }
        let original = workspaces[index]
        workspaces[index].sideGateOrder = nextFolderOrder(side: true)
        workspaces[index].sideGateAdded = true
        guard save() else { workspaces[index] = original; return false }
        return true
    }

    @discardableResult
    func moveToSideGates(_ workspace: WorkspaceRecord,
                         revokeMainAccess: ((String) async -> Bool)? = nil) async -> Bool {
        guard let current = workspaces.first(where: { $0.id == workspace.id && $0.belongsToMainGate }),
              current.sideGateRemovalState == nil, busy[workspace.id] == nil else { return false }
        busy[workspace.id] = .move
        defer { busy[workspace.id] = nil }
        let sourceID = workspace.id.uuidString.lowercased()
        let revoked: Bool
        if let revokeMainAccess { revoked = await revokeMainAccess(sourceID) }
        else { revoked = await gateway.perform("remove-root", sourceID: sourceID) }
        guard revoked else {
            alertMessage = gateway.message ?? "未能停止 Main Gate 分享，Folder 未有搬移。請稍後再試。"
            return false
        }
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }),
              workspaces[index].sideGateRemovalState == nil else { return false }
        let original = workspaces[index]
        if !original.belongsToSideGates { workspaces[index].sideGateOrder = nextFolderOrder(side: true) }
        workspaces[index].sideGateAdded = true
        workspaces[index].mainGateAdded = false
        guard save() else { workspaces[index] = original; return false }
        return true
    }

    func toggleSideGate(_ workspace: WorkspaceRecord) async {
        guard let current = operableSideGate(workspace), busy[workspace.id] == nil else { return }
        let connection = sideGateway(for: current)
        guard connection.statusConfirmed, let running = connection.status?.running,
              connection.status?.state != "unknown", !connection.working, !connection.reconnecting else { return }
        let action = running ? "stop" : "start-local"
        if !running, !FileManager.default.fileExists(atPath: current.path) {
            alertMessage = "搵唔到呢個 Folder：\(current.path)"
            return
        }
        busy[current.id] = running ? .stop : .start
        defer { busy[current.id] = nil }
        if !(await connection.perform(action)) { alertMessage = connection.message }
        await refresh(current)
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
            alertMessage = "請貼上 MCP Connection 入面嘅 HTTPS Server URL（/mcp）。"
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
            _ = try await client.start(workspace)
            await refresh(workspace, forceConnectionCheck: true)
        } catch {
            await refresh(workspace)
            if reportErrors { alertMessage = "\(workspace.name) 連線未能開啟。請喺 Gate setup 重試。" }
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
            _ = try await client.start(workspace)
            await refresh(workspace, forceConnectionCheck: true)
        } catch {
            await refresh(workspace)
            if reportErrors { alertMessage = "\(workspace.name) 連線未能修復。請喺 Gate setup 重新檢查。" }
        }
    }

    private func waitForStop(_ workspace: WorkspaceRecord) async throws {
        for _ in 0..<40 {
            if try await client.status(for: workspace).running == false { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw C2CClientError.commandFailed("現有連線未完全停止，請稍後再試。")
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
            guard busy[workspace.id] == nil else { continue }
            busy[workspace.id] = .restart
            invalidateConnection(workspace)
            do {
                _ = try await client.reconnect(workspace)
                await refresh(workspace, forceConnectionCheck: true)
            } catch {
                await refresh(workspace)
                alertMessage = "\(workspace.name)：\(error.localizedDescription)"
            }
            busy[workspace.id] = nil
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
        try? FileManager.default.removeItem(at: GateUIContext.side(workspace).setupFile(in: configURL.deletingLastPathComponent()))
        sideGateConnections[workspace.id] = nil
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
