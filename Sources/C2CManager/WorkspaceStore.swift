import AppKit
import CryptoKit
import Combine
import Foundation

enum WorkspaceStoreError: LocalizedError {
    case unreadable(URL, Error)
    case invalid(URL, String)
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url, let error):
            return "Unable to read Boundas Gate Folder state (\(url.lastPathComponent)): \(error.localizedDescription)"
        case .invalid(_, let message):
            return "Boundas Gate Folder state is invalid and was left untouched. \(message)"
        case .persistence(let error):
            return "Unable to save Boundas Gate Folder state: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    let gateway: SharedGatewayStore
    @Published private(set) var workspaces: [WorkspaceRecord] = []
    @Published private(set) var busy: [UUID: WorkspaceOperation] = [:]
    @Published var selectedID: UUID? = SharedGatewayStore.selectionID
    @Published var alertMessage: String?
    @Published var showingAddPath = false

    private var quitting = false
    private let client: any SideGateClient
    private(set) var sideGateConnections: [UUID: SharedGatewayStore] = [:]
    private var sideGateSubscriptions: [UUID: AnyCancellable] = [:]
    private let makeSideGateway: @MainActor (WorkspaceRecord) -> SharedGatewayStore
    private let identityForPath: (String) -> String
    private let canonicalPathResolver: (String) -> String
    private let automaticallyRefresh: Bool
    private let configURL: URL
    private let c2cLogDirectory: URL
    private var lastPersistenceError: Error?

    var runningCount: Int { sideGateWorkspaces.filter { $0.canOperateSideGate && sideGateConnections[$0.id]?.status?.running == true }.count }
    var healthyConnectionCount: Int { sideGateWorkspaces.filter { $0.canOperateSideGate && sideGateConnections[$0.id]?.usable == true }.count }
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
         gateway: SharedGatewayStore? = nil, automaticallyRefresh: Bool = true,
         sideGatewayFactory: (@MainActor (WorkspaceRecord) -> SharedGatewayStore)? = nil,
         c2cIDResolver: ((String) -> String)? = nil,
         canonicalPathResolver: ((String) -> String)? = nil) throws {
        self.makeSideGateway = sideGatewayFactory ?? {
            SharedGatewayStore(automaticallyRefresh: false, gateSourceID: $0.id.uuidString.lowercased())
        }
        self.automaticallyRefresh = automaticallyRefresh
        self.identityForPath = c2cIDResolver ?? Self.c2cID(for:)
        self.canonicalPathResolver = canonicalPathResolver ?? Self.canonicalPath(_:)
        self.configURL = configURL ?? AppDataPaths.current.workspaces
        self.client = client ?? C2CClient()
        self.gateway = gateway ?? SharedGatewayStore(automaticallyRefresh: false)
        c2cLogDirectory = AppDataPaths.current.c2cLogs
        try load()
        guard automaticallyRefresh else { return }
        self.gateway.startAutomaticRefresh()
        Task { [weak self] in
            while let self {
                await self.refreshAll()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    /// Freeze observations/recovery only; keep all persistent user intent intact.
    func suspendForAppQuit() {
        quitting = true
        gateway.suspendForAppQuit()
        for connection in sideGateConnections.values { connection.suspendForAppQuit() }
    }

    // The same owner is used by background observation, sidebar and detail.
    func sideGateway(for workspace: WorkspaceRecord) -> SharedGatewayStore {
        if let existing = sideGateConnections[workspace.id] { return existing }
        let connection = makeSideGateway(workspace)
        if quitting { connection.suspendForAppQuit() }
        guard let current = workspaces.first(where: { $0.id == workspace.id && $0.belongsToSideGates }) else {
            // An old view/async caller must not recreate a removed cache entry.
            connection.suspendForDecommission()
            return connection
        }
        if !current.canOperateSideGate { connection.suspendForDecommission() }
        sideGateConnections[workspace.id] = connection
        sideGateSubscriptions[workspace.id] = connection.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        objectWillChange.send()
        return connection
    }

    private func observeSideGate(_ workspace: WorkspaceRecord) async {
        guard operableSideGate(workspace) != nil, busy[workspace.id] == nil else { return }
        let connection = sideGateway(for: workspace)
        guard !connection.working else { return }
        await connection.refresh(background: true)
        guard operableSideGate(workspace) != nil, busy[workspace.id] == nil,
              sideGateConnections[workspace.id] === connection else { return }
        rememberEndpoint(workspace, connection: connection)
        await connection.recoverIfNeeded()
        guard operableSideGate(workspace) != nil, busy[workspace.id] == nil,
              sideGateConnections[workspace.id] === connection else { return }
        rememberEndpoint(workspace, connection: connection)
    }

    private func rememberEndpoint(_ workspace: WorkspaceRecord, connection: SharedGatewayStore) {
        guard let url = connection.status?.mcpURL,
              let index = workspaces.firstIndex(where: { $0.id == workspace.id && $0.canOperateSideGate }) else { return }
        let original = workspaces[index]
        workspaces[index].observeMCPURL(url)
        if workspaces[index] != original, !save() { workspaces[index] = original }
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
        free(resolved)
        let canonicalPath = canonicalPathResolver(expanded)
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

        let c2cID = identityForPath(canonicalPath)
        if Self.hasIdentityCollision(canonicalPath: canonicalPath, c2cID: c2cID, in: workspaces,
                                     canonicalizer: canonicalPathResolver) {
            alertMessage = "This Folder conflicts with an existing Boundas Gate Folder identity and can't be added safely."
            return false
        }
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
        if side && automaticallyRefresh { Task { await observeSideGate(record) } }
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
        rememberEndpoint(current, connection: connection)
    }

    func rename(_ workspace: WorkspaceRecord, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let original = workspaces[index]
        workspaces[index].name = trimmed
        if !save() { workspaces[index] = original }
    }

    // One polling pass; independent of the currently selected Gate.
    func refreshAll() async {
        guard !quitting else { return }
        for workspace in sideGateWorkspaces where workspace.canOperateSideGate && busy[workspace.id] == nil {
            await observeSideGate(workspace)
        }
    }

    private func performSideGate(_ action: String, workspace: WorkspaceRecord) async {
        guard !quitting else { return }
        guard let current = operableSideGate(workspace), busy[current.id] == nil else { return }
        let connection = sideGateway(for: current)
        guard !connection.working, !connection.reconnecting else { return }
        if action == "start-local", !FileManager.default.fileExists(atPath: current.path) {
            alertMessage = "搵唔到呢個 Folder：\(current.path)"
            return
        }
        busy[current.id] = action == "stop" ? .stop : .start
        defer { busy[current.id] = nil }
        if !(await connection.perform(action)) { alertMessage = connection.message }
        if operableSideGate(current) != nil { rememberEndpoint(current, connection: connection) }
    }

    func startAll() async {
        for workspace in sideGateWorkspaces where workspace.canOperateSideGate
            && sideGateConnections[workspace.id]?.status?.running != true {
            await performSideGate("start-local", workspace: workspace)
        }
    }

    func stopAll() async {
        for workspace in sideGateWorkspaces where workspace.canOperateSideGate
            && sideGateConnections[workspace.id]?.status?.running == true {
            await performSideGate("stop", workspace: workspace)
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
              busy[workspace.id] == nil,
              sideGateConnections[workspace.id]?.working != true,
              sideGateConnections[workspace.id]?.reconnecting != true else { return }
        let original = workspaces[index]
        workspaces[index].sideGateRemovalState = .removing
        workspaces[index].sideGateRemovalError = nil
        guard save() else { workspaces[index] = original; return }
        busy[workspace.id] = .remove
        defer { busy[workspace.id] = nil }
        sideGateConnections[workspace.id]?.suspendForDecommission()
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
            let persistedRetry = save()
            alertMessage = persistedRetry
                ? "Remove Side Gate 未完成，可以 Retry：\(error.localizedDescription)"
                : "Remove Side Gate 已完成外部清理，但未能儲存 Retry 狀態；請保留此設定檔並稍後重試。"
            return
        }
        try? FileManager.default.removeItem(at: GateUIContext.side(workspace).setupFile(in: configURL.deletingLastPathComponent()))
        sideGateSubscriptions[workspace.id] = nil
        sideGateConnections[workspace.id] = nil
        objectWillChange.send()
        if selectedID == workspace.id { selectedID = nil }
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openFolder(_ workspace: WorkspaceRecord) {
        NSWorkspace.shared.open(URL(fileURLWithPath: workspace.path))
    }

    func openLogs(_ workspace: WorkspaceRecord) {
        let file = c2cLogDirectory.appendingPathComponent("bridge-\(workspace.c2cID).out.log")
        let target = FileManager.default.fileExists(atPath: file.path) ? file : c2cLogDirectory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func load() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path) else { return }
        let data: Data
        do { data = try Data(contentsOf: configURL) }
        catch { throw WorkspaceStoreError.unreadable(configURL, error) }
        let saved: [WorkspaceRecord]
        do { saved = try JSONDecoder().decode([WorkspaceRecord].self, from: data) }
        catch { throw WorkspaceStoreError.invalid(configURL, "JSON could not be decoded.") }
        try Self.validate(saved, source: configURL)
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
        if workspaces != saved, !save() {
            throw WorkspaceStoreError.persistence(lastPersistenceError ?? CocoaError(.fileWriteUnknown))
        }
    }

    private static func validate(_ records: [WorkspaceRecord], source: URL) throws {
        var seenIDs = Set<UUID>()
        var seenPaths = Set<String>()
        var seenC2CIDs: [String: String] = [:]
        for record in records {
            guard !record.path.isEmpty, record.path.hasPrefix("/"),
                  Self.isValidC2CID(record.c2cID) else {
                throw WorkspaceStoreError.invalid(source, "A Folder identity is structurally invalid.")
            }
            guard seenIDs.insert(record.id).inserted else {
                throw WorkspaceStoreError.invalid(source, "Duplicate Folder identities were found.")
            }
            let canonical = Self.canonicalPath(record.path)
            guard seenPaths.insert(canonical).inserted else {
                throw WorkspaceStoreError.invalid(source, "Duplicate Folder paths were found.")
            }
            if let existing = seenC2CIDs[record.c2cID], existing != canonical {
                throw WorkspaceStoreError.invalid(source, "Two different Folders share one identity.")
            }
            seenC2CIDs[record.c2cID] = canonical
        }
    }

    private static func isValidC2CID(_ value: String) -> Bool {
        value.range(of: #"^[a-f0-9]{12}$"#, options: .regularExpression) != nil
    }

    static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            let value = String(cString: resolved)
            free(resolved)
            return value
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func c2cID(for canonicalPath: String) -> String {
        SHA256.hash(data: Data(canonicalPath.lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    static func hasIdentityCollision(canonicalPath path: String, c2cID: String, in records: [WorkspaceRecord],
                                     canonicalizer: ((String) -> String)? = nil) -> Bool {
        let resolve = canonicalizer ?? { Self.canonicalPath($0) }
        return records.contains { $0.c2cID == c2cID && resolve($0.path) != path }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            let directory = configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(workspaces)
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            lastPersistenceError = nil
            return true
        } catch {
            lastPersistenceError = error
            alertMessage = "無法儲存 Folders：\(error.localizedDescription)"
            return false
        }
    }
}
