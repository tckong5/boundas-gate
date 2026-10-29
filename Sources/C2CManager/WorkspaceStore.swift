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
    private var locationWarningShown = false
    private var gatewayPathSyncPending = false

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

    /// Reconnect a record whose stable reference could not be resolved. An
    /// explicit user selection is required; the old record is never silently
    /// rebound during load.
    func locateFolder(_ workspace: WorkspaceRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Locate Folder"
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let canonical = canonicalPathResolver(url.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            alertMessage = "揀選嘅位置唔係 Folder。"
            return
        }
        guard !workspaces.contains(where: { $0.id != workspace.id && canonicalPathResolver($0.path) == canonical }) else {
            alertMessage = "呢個 Folder 已經加入。"
            return
        }
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        let original = workspaces[index]
        if let message = Self.relocationValidationError(originalPath: original.path,
                                                        bookmark: original.folderBookmark,
                                                        storedFileIdentity: original.folderFileIdentity,
                                                        selectedPath: canonical) {
            alertMessage = message
            return
        }
        workspaces[index].path = canonical
        workspaces[index].folderBookmark = Self.makeFolderBookmark(for: canonical)
        workspaces[index].folderFileIdentity = Self.fileIdentity(canonical)
        guard save() else { workspaces[index] = original; return }
        gatewayPathSyncPending = true
        Task { await synchronizeRelocatedFolders() }
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
        record.folderBookmark = Self.makeFolderBookmark(for: canonicalPath)
        record.folderFileIdentity = Self.fileIdentity(canonicalPath)
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
        await synchronizeRelocatedFolders()
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
        let normalized = saved.map { record in
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
        let relocated = try Self.reconcileFolderLocations(normalized, source: configURL)
        workspaces = relocated
        if workspaces != saved, !save() {
            throw WorkspaceStoreError.persistence(lastPersistenceError ?? CocoaError(.fileWriteUnknown))
        }
        if workspaces != saved || workspaces.contains(where: { $0.folderIdentityRecovery != nil }) {
            gatewayPathSyncPending = true
        }
    }

    private func synchronizeRelocatedFolders() async {
        guard !quitting else { return }
        let original = workspaces
        do {
            let updated = try Self.reconcileFolderLocations(workspaces, source: configURL)
            if updated != original {
                workspaces = updated
                guard save() else { workspaces = original; return }
                gatewayPathSyncPending = true
            }
            if gatewayPathSyncPending { await synchronizeGatewayPaths() }
        } catch {
            if !locationWarningShown {
                locationWarningShown = true
                alertMessage = error.localizedDescription
            }
        }
    }

    private func synchronizeGatewayPaths() async {
        // Reconcile existing roots only: recovery must not enable every added
        // Folder or reset disabled-root authorization epochs.
        guard await gateway.perform("sync-folder-identities") else { return }
        gatewayPathSyncPending = false
        for connection in sideGateConnections.values { await connection.refresh(background: true) }
    }

    private static func reconcileFolderLocations(_ records: [WorkspaceRecord], source: URL) throws -> [WorkspaceRecord] {
        var updated = records
        for index in updated.indices {
            let original = updated[index]
            if let bookmark = original.folderBookmark, let resolved = resolveFolderBookmark(bookmark) {
                let currentPath = canonicalPath(original.path)
                if resolved.path != currentPath {
                    // A bookmark can prove that the Folder moved. If the old
                    // path is occupied by another object, require the old
                    // identity to match before following the bookmark; this
                    // keeps replacement-at-the-old-path fail-closed.
                    if FileManager.default.fileExists(atPath: original.path) {
                        let oldIdentity = fileIdentity(original.path)
                        guard let expectedIdentity = original.folderFileIdentity,
                              oldIdentity == expectedIdentity else { continue }
                    }
                    guard !updated.enumerated().contains(where: { $0.offset != index && canonicalPath($0.element.path) == resolved.path }) else { continue }
                }
                if let expectedIdentity = original.folderFileIdentity,
                   let resolvedIdentity = fileIdentity(resolved.path),
                   expectedIdentity != resolvedIdentity,
                   !sameInode(expectedIdentity, resolvedIdentity) {
                    // A changed inode indicates replacement. A changed
                    // device with the same inode is the remount case that a
                    // bookmark can safely recover.
                    continue
                }
                // The bookmark is the stable proof. Refresh the cached
                // device/inode hint after a remount instead of treating a
                // changed device number as a replacement Folder.
                guard let resolvedIdentity = fileIdentity(resolved.path) else { continue }
                if let previous = original.folderFileIdentity, previous != resolvedIdentity {
                    // The recovery handoff is intentionally limited to an
                    // unchanged path and inode, verified by the bookmark.
                    guard resolved.path == original.path else { continue }
                    updated[index].folderIdentityRecovery = FolderIdentityRecovery(
                        previous: previous, current: resolvedIdentity, path: resolved.path)
                }
                updated[index].path = resolved.path
                updated[index].folderFileIdentity = resolvedIdentity
                if resolved.stale { updated[index].folderBookmark = makeFolderBookmark(for: resolved.path) }
            } else if FileManager.default.fileExists(atPath: original.path) {
                if let expectedIdentity = original.folderFileIdentity,
                   let currentIdentity = fileIdentity(original.path), expectedIdentity != currentIdentity {
                    // Without a resolvable bookmark there is no safe proof
                    // that a remounted path is still the authorized Folder.
                    continue
                }
                // Legacy records gain the stable reference lazily while their
                // original location is still available.
                updated[index].folderBookmark = makeFolderBookmark(for: original.path)
                updated[index].folderFileIdentity = fileIdentity(original.path)
            }
        }
        try validate(updated, source: source)
        return updated
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

    static func makeFolderBookmark(for path: String) -> Data? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: [.fileResourceIdentifierKey], relativeTo: nil)
    }

    static func resolveFolderBookmark(_ data: Data) -> (path: String, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return (canonicalPath(url.path), stale)
    }

    /// Returns nil only when the selected Folder can safely retain the
    /// existing WorkspaceRecord identity. A user selection by itself is not
    /// evidence of identity when no stable reference remains.
    static func relocationValidationError(originalPath: String,
                                          bookmark: Data?,
                                          storedFileIdentity: String?,
                                          selectedPath: String) -> String? {
        let selectedIdentity = fileIdentity(selectedPath)
        if let storedFileIdentity {
            guard selectedIdentity == storedFileIdentity else {
                return "未能確認揀選嘅 Folder 係原本嗰個 Folder；狀態未有改動。"
            }
        }
        if let bookmark {
            guard let resolved = resolveFolderBookmark(bookmark),
                  let resolvedIdentity = fileIdentity(resolved.path),
                  selectedIdentity == resolvedIdentity else {
                return "未能確認揀選嘅 Folder 係原本嗰個 Folder；狀態未有改動。"
            }
            return nil
        }
        if storedFileIdentity != nil { return nil }
        if FileManager.default.fileExists(atPath: originalPath) {
            return "原本 Folder 仍然存在，唔需要重新定位。"
        }
        return "未能確認原本 Folder 身份；請先移除，再以新 Folder 加入。"
    }

    nonisolated static func fileIdentity(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device.stringValue):\(inode.stringValue)"
    }

    private static func sameInode(_ lhs: String, _ rhs: String) -> Bool {
        lhs.split(separator: ":", maxSplits: 1).dropFirst().first ==
            rhs.split(separator: ":", maxSplits: 1).dropFirst().first
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
