import AppKit
import SwiftUI

@main
struct C2CManagerApp: App {
    @NSApplicationDelegateAdaptor(ManagerAppDelegate.self) private var appDelegate
    @StateObject private var store = WorkspaceStore()

    var body: some Scene {
        Window(AppDataPaths.current.windowTitle, id: "manager") {
            ManagerWindow(store: store, appDelegate: appDelegate)
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 900, height: 590)

        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .renderingMode(.original)
                .accessibilityLabel("Boundas Gate")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
private final class ManagerAppDelegate: NSObject, NSApplicationDelegate {
    var openManagerWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let openManagerWindow else { return true }
        openManagerWindow()
        sender.activate(ignoringOtherApps: true)
        return false
    }
}

private struct MenuBarContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gateway: SharedGatewayStore
    @Environment(\.openWindow) private var openWindow

    init(store: WorkspaceStore) {
        self.store = store
        self.gateway = store.gateway
    }

    var body: some View {
        Text("Main Gate：\(gateway.connectionTitle)")
        Divider()
        Button("Main Gate…") {
            store.selectedID = SharedGatewayStore.selectionID
            showManager()
        }
        Button(gateway.connectionState.button) {
            store.selectedID = SharedGatewayStore.selectionID
            showManager()
            Task {
                switch gateway.connectionState {
                case .checking, .unknown: await gateway.refresh()
                case .stopped, .needsRepair: await gateway.repair()
                case .ready: gateway.copyURL(openChatGPT: true)
                }
            }
        }
        .disabled(gateway.working || gateway.checking
                  )
        if gateway.statusConfirmed && (gateway.status?.running == true || gateway.status?.desiredRunning == true) {
            if gateway.status?.running == true && gateway.status?.state != "unknown" {
                Button("重啟共用連線") {
                    store.selectedID = SharedGatewayStore.selectionID
                    showManager()
                    Task { await gateway.restart() }
                }.disabled(gateway.working || gateway.checking)
            }
            Button("停止共用連線") {
                store.selectedID = SharedGatewayStore.selectionID
                showManager()
                Task { _ = await gateway.perform("stop") }
            }.disabled(gateway.working)
        }
        Divider()
        Text("Side Gates：\(store.healthyConnectionCount) 個就緒")
        if store.sideGateWorkspaces.isEmpty {
            Text("尚未加入 Side Gate")
        }
        ForEach(store.sideGateWorkspaces) { workspace in
            Menu {
                Text(workspace.path)
                if let status = store.statuses[workspace.id] {
                    Text(status.running == false ? "連線未開啟" : store.diagnostics[workspace.id]?.isUsable == true ? "Mac 連線已準備好" : "連線需要處理")
                }
                Divider()
                Button("複製 ChatGPT 連線地址") { store.copyURL(workspace) }
                    .disabled(store.diagnostics[workspace.id]?.isUsable != true)
                if let pairing = store.pairingCodes[workspace.id], pairing.expiresAt > Date() {
                    Text("配對碼：\(pairing.value)")
                    Button("Copy Pairing Code") { store.copyPairingCode(workspace) }
                }
                Button("Generate New Pairing Code…") {
                    store.selectedID = workspace.id
                    showManager()
                    Task { await store.generatePairingCode(workspace) }
                }
                .disabled(store.diagnostics[workspace.id]?.isUsable != true)
                Button("帶我設定／修復連線…") {
                    store.selectedID = workspace.id
                    store.guidedWorkspaceID = workspace.id
                    showManager()
                }
                if store.statuses[workspace.id]?.running == true {
                    Button("停止連線") { Task { await store.stop(workspace) } }
                }
                Divider()
                Button("Open Logs") { store.openLogs(workspace) }
                Button("Open Folder") { store.openFolder(workspace) }
                Button("Manage Side Gate…") {
                    store.selectedID = workspace.id
                    showManager()
                }
            } label: {
                Label(workspace.name, systemImage: store.statuses[workspace.id]?.running == true ? "circle.fill" : "circle")
            }
            .disabled(store.busy[workspace.id] != nil)
        }
        Divider()
        Button("Add Folders…", systemImage: "plus") { store.addFolder() }
        Button("Add Folder by Path…", systemImage: "text.cursor") {
            showManager()
            store.showingAddPath = true
        }
        Button("Open All Side Gates") {
            Task {
                await store.startAll()
                if let workspace = store.workspaces.first(where: { store.pairingCodes[$0.id] != nil }) {
                    store.selectedID = workspace.id
                    showManager()
                }
            }
        }
            .disabled(store.sideGateWorkspaces.isEmpty)
        Button("Close All Side Gates") { Task { await store.stopAll() } }
            .disabled(store.runningCount == 0)
        Divider()
        Button("Manage Folders…") { showManager() }
        Button("Open ChatGPT") { store.openChatGPT() }
        Button("Quit Boundas Gate") { NSApp.terminate(nil) }
    }

    private func showManager() {
        openWindow(id: "manager")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ManagerWindow: View {
    private enum GateMode {
        case main, side
    }

    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gateway: SharedGatewayStore
    @State private var mainFolderSelection: UUID?
    @State private var sideFolderSelection: UUID?
    @State private var sharedSelection: Set<String> = []
    @State private var lastSavedSharedSelection: Set<String>?
    @State private var renamingFolderID: UUID?
    @State private var renamedFolderName = ""
    @FocusState private var renameFocus: UUID?
    let appDelegate: ManagerAppDelegate
    @Environment(\.openWindow) private var openWindow

    private var gateMode: GateMode {
        store.selectedID == SharedGatewayStore.selectionID ? .main : .side
    }

    private var gateModeBinding: Binding<GateMode> {
        Binding(
            get: { gateMode },
            set: { mode in
                store.selectedID = mode == .main ? SharedGatewayStore.selectionID : sideFolderSelection
            }
        )
    }

    private var savedSharedSelection: Set<String> {
        Set((gateway.status?.roots ?? []).map { $0.sourceID.lowercased() })
    }

    init(store: WorkspaceStore, appDelegate: ManagerAppDelegate) {
        self.store = store
        self.gateway = store.gateway
        self.appDelegate = appDelegate
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                GateSelector(isMainGate: Binding(
                    get: { gateMode == .main },
                    set: { gateModeBinding.wrappedValue = $0 ? .main : .side }
                ))

                HStack(spacing: 6) {
                    Text("Folders")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    RepositoryAddAction(byPath: true) { store.showingAddPath = true }
                    RepositoryAddAction(byPath: false) { store.addFolder() }
                }
                .padding(.horizontal, 16).padding(.top, 6)

                if gateMode == .main {
                    List(selection: $mainFolderSelection) {
                        ForEach(store.workspaces) { workspace in
                            HStack(spacing: 10) {
                                mainFolderLabel(workspace)
                                Spacer(minLength: 8)
                                MainGateFolderPasscodeButton(
                                    gateway: gateway, workspace: workspace,
                                    configurationChanged: sharedSelection != savedSharedSelection
                                )
                                Toggle("Main Gate access for \(workspace.name)", isOn: Binding(
                                    get: { sharedSelection.contains(workspace.id.uuidString.lowercased()) },
                                    set: { enabled in
                                        let id = workspace.id.uuidString.lowercased()
                                        if enabled { sharedSelection.insert(id) } else { sharedSelection.remove(id) }
                                    }
                                ))
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden().fixedSize()
                                .disabled(gateway.working || !gateway.statusConfirmed)
                            }
                            .padding(.vertical, 2).tag(workspace.id)
                            .contextMenu {
                                Button("Rename") { beginRename(workspace) }
                                Button("Remove Folder", role: .destructive) { store.removeFolder(workspace) }
                                    .disabled(workspace.belongsToSideGates)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onKeyPress(.return) {
                        guard renamingFolderID == nil,
                              let workspace = store.workspaces.first(where: { $0.id == mainFolderSelection }) else {
                            return .ignored
                        }
                        beginRename(workspace)
                        return .handled
                    }
                    .overlay {
                        if store.workspaces.isEmpty { SidebarEmptyFolders() }
                    }
                    if sharedSelection != savedSharedSelection {
                        Button("儲存變更") {
                            Task { _ = await gateway.perform("configure", selectedIDs: sharedSelection.sorted()) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(gateway.working || !gateway.statusConfirmed)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                    }
                } else {
                    List(selection: $store.selectedID) {
                        ForEach(store.sideGateWorkspaces) { workspace in
                            HStack(spacing: 10) {
                                Image(systemName: store.statuses[workspace.id]?.running == true ? "circle.fill" : "circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(workspace.sideGateRemovalState != nil ? Color.orange : store.diagnostics[workspace.id]?.isUsable == true ? Color.green : store.statuses[workspace.id]?.running == true ? Color.orange : Color.secondary)
                                folderLabel(workspace)
                            }
                            .padding(.vertical, 2).tag(workspace.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .overlay {
                        if store.sideGateWorkspaces.isEmpty { SidebarEmptyFolders() }
                    }
                }
            }
            .toolbar {
                Button("重新檢查", systemImage: "arrow.clockwise") {
                    Task { await gateway.refresh() }
                    Task { await store.refreshAll() }
                }.disabled(gateway.working || gateway.checking)
            }
            .frame(minWidth: 270)
        } detail: {
            if gateMode == .main {
                SharedGatewayView(store: store, gateway: store.gateway, selected: $sharedSelection)
            } else if let workspace = store.sideGateWorkspaces.first(where: { $0.id == store.selectedID }) {
                WorkspaceDetail(store: store, workspace: workspace).id(workspace.id)
            } else {
                ContentUnavailableView("選擇一個 Folder", systemImage: "folder", description: Text("加入任何 folder，然後管理佢嘅 Side Gate。"))
            }
        }
        .alert("Boundas Gate", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("確定", role: .cancel) { store.alertMessage = nil }
        } message: {
            Text(store.alertMessage ?? "")
        }
        .sheet(isPresented: $store.showingAddPath) {
            AddPathSheet(store: store)
        }
        .onAppear {
            appDelegate.openManagerWindow = { openWindow(id: "manager") }
            syncSharedSelection()
        }
        .onChange(of: store.selectedID, initial: true) { _, id in
            if let id, id != SharedGatewayStore.selectionID { sideFolderSelection = id }
            if id != SharedGatewayStore.selectionID { cancelRename() }
        }
        .onChange(of: mainFolderSelection) { _, id in
            if let renamingFolderID, renamingFolderID != id { cancelRename() }
        }
        .onChange(of: gateway.status?.roots) { _, _ in syncSharedSelection() }
        .onChange(of: gateway.statusConfirmed) { _, confirmed in
            if confirmed { syncSharedSelection() }
        }
        .onChange(of: store.workspaces) { previous, records in
            let ids = Set(records.map(\.id))
            sharedSelection.formIntersection(Set(ids.map { $0.uuidString.lowercased() }))
            if store.selectedID == SharedGatewayStore.selectionID, previous.isEmpty, let first = records.first {
                sharedSelection.insert(first.id.uuidString.lowercased())
            }
            if let id = mainFolderSelection, !ids.contains(id) { mainFolderSelection = nil }
            if let id = sideFolderSelection, !records.contains(where: { $0.id == id && $0.belongsToSideGates }) { sideFolderSelection = nil }
            if let id = renamingFolderID, !ids.contains(id) { cancelRename() }
        }
    }

    private func mainFolderLabel(_ workspace: WorkspaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if renamingFolderID == workspace.id {
                TextField("Folder name", text: $renamedFolderName)
                    .textFieldStyle(.plain).fontWeight(.medium)
                    .focused($renameFocus, equals: workspace.id)
                    .onAppear { renameFocus = workspace.id }
                    .onSubmit {
                        store.rename(workspace, to: renamedFolderName)
                        cancelRename()
                    }
                    .onExitCommand { cancelRename() }
            } else {
                Text(workspace.name).fontWeight(.medium).lineLimit(1)
            }
            Text(sidebarPath(workspace.path))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head).help(workspace.path)
        }
    }

    private func beginRename(_ workspace: WorkspaceRecord) {
        mainFolderSelection = workspace.id
        renamedFolderName = workspace.name
        renamingFolderID = workspace.id
    }

    private func cancelRename() {
        renamingFolderID = nil
        renameFocus = nil
    }

    private func folderLabel(_ workspace: WorkspaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(workspace.name).fontWeight(.medium).lineLimit(1)
            Text(sidebarPath(workspace.path))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head).help(workspace.path)
        }
    }

    private func sidebarPath(_ path: String) -> String {
        let abbreviated = NSString(string: path).abbreviatingWithTildeInPath
        let components = abbreviated.split(separator: "/")
        guard components.count > 3 else { return abbreviated }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    private func syncSharedSelection() {
        guard gateway.statusConfirmed, gateway.status != nil else { return }
        // Permissions come from configured roots, independently of runtime state.
        // Preserve the draft while navigating or receiving background refreshes.
        if lastSavedSharedSelection.map({ sharedSelection == $0 }) ?? sharedSelection.isEmpty {
            sharedSelection = savedSharedSelection
        }
        lastSavedSharedSelection = savedSharedSelection
    }
}

private struct SidebarEmptyFolders: View {
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 6) {
                Text("Open your first Gate")
                    .font(.system(size: 13, weight: .medium))
                Text("Choose a folder to connect through Boundas Gate.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, max(48, geometry.size.height * 0.24))
        }
        .allowsHitTesting(false)
    }
}

private struct RepositoryAddAction: View {
    let byPath: Bool
    let action: () -> Void
    @State private var hovering = false

    private var title: String { byPath ? "Add by Path" : "Add Folder" }

    var body: some View {
        Button(action: action) {
            Group {
                if byPath {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("/…").font(.system(size: 12, weight: .medium, design: .monospaced))
                        Image(systemName: "plus")
                            .font(.system(size: 6, weight: .semibold))
                            .offset(y: -4)
                    }
                } else {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14, weight: .regular))
                }
            }
            .frame(width: 22, height: 16)
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
    }
}

private struct AddPathSheet: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Folder by Path").font(.title2.bold())
            Text("貼上 folder 路徑；只有你加入嘅 folder 會成為 C2C workspace。")
                .foregroundStyle(.secondary)
            TextField("~/Projects/my-project", text: $path)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("加入 Folder", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func add() {
        if store.addPath(path) {
            dismiss()
        } else {
            errorMessage = store.alertMessage
            store.alertMessage = nil
        }
    }
}

private struct WorkspaceDetail: View {
    @ObservedObject var store: WorkspaceStore
    let workspace: WorkspaceRecord
    @State private var proposedName = ""
    @State private var confirmRemove = false
    @StateObject private var folderGateway: SharedGatewayStore

    init(store: WorkspaceStore, workspace: WorkspaceRecord) {
        self.store = store
        self.workspace = workspace
        _folderGateway = StateObject(wrappedValue: SharedGatewayStore(automaticallyRefresh: false, gateSourceID: workspace.id.uuidString.lowercased()))
    }

    private var status: WorkspaceStatus? { store.statuses[workspace.id] }
    private var working: Bool { store.busy[workspace.id] != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.name).font(.largeTitle.bold())
                    Text(workspace.path)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !FileManager.default.fileExists(atPath: workspace.path) {
                        Label("Folder 已不存在或未連接", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Text("呢頁管理 Side Gate；Main Gate 狀態及 Folder 分享設定互相獨立。")
                    .font(.callout).foregroundStyle(.secondary)
                if let removal = workspace.sideGateRemovalState {
                    Text(removal == .removing ? "Removing…" : "Removing Failed")
                        .font(.headline).foregroundStyle(.orange)
                    if let error = workspace.sideGateRemovalError {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    }
                    if removal == .failed {
                        Button("Retry") { Task { await store.removeSideGate(workspace) } }
                            .disabled(working)
                    }
                } else {
                    ConnectionStatusView(store: store, workspace: workspace)
                    HStack {
                        Text("Passcode Protection").font(.callout)
                        MainGateFolderPasscodeButton(gateway: folderGateway, workspace: workspace, configurationChanged: false)
                    }
                    .task(id: status?.running) { await folderGateway.refresh() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.provider == .tailscale ? "連線方式：Tailscale 固定地址" : "連線方式：Cloudflare 臨時地址")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("設定固定地址…", systemImage: "link") { store.stableWorkspaceID = workspace.id }
                        .disabled(working)
                }

                if store.diagnostics[workspace.id]?.isUsable == true {
                    DisclosureGroup("連線地址／配對碼（有需要時用）") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(status?.mcpURL ?? "")
                                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Button("複製連線地址", systemImage: "doc.on.doc") { store.copyURL(workspace) }.disabled(working)
                            pairingSection
                        }.padding(.top, 12)
                    }
                }

                HStack(spacing: 10) {
                    if status?.running == true {
                        Button("停止獨立連線", systemImage: "stop.fill") { Task { await store.stop(workspace) } }
                    }
                    if let operation = store.busy[workspace.id] {
                        ProgressView().controlSize(.small)
                        Text(operation.rawValue).foregroundStyle(.secondary)
                    }
                }
                .disabled(working || !FileManager.default.fileExists(atPath: workspace.path))

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Folder").font(.headline)
                    HStack {
                        TextField("名稱", text: $proposedName)
                            .onSubmit { store.rename(workspace, to: proposedName) }
                        Button("儲存名稱") { store.rename(workspace, to: proposedName) }
                    }
                    HStack {
                        Button("Open Folder") { store.openFolder(workspace) }
                        Button("Open Logs") { store.openLogs(workspace) }
                        Button("Open ChatGPT Plugins") { store.openChatGPT() }
                        Spacer()
                        Button(workspace.sideGateRemovalState == .failed ? "Retry Remove Side Gate" : "Remove Side Gate", role: .destructive) { confirmRemove = true }
                            .disabled(working)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(workspace.name)
        .sheet(isPresented: Binding(
            get: { store.stableWorkspaceID == workspace.id },
            set: { if !$0 { store.stableWorkspaceID = nil } }
        )) {
            StableConnectionView(store: store, workspace: workspace)
        }
        .onAppear { proposedName = workspace.name }
        .onChange(of: workspace.id) { _, _ in proposedName = workspace.name }
        .onChange(of: workspace.name) { _, newName in proposedName = newName }
        .confirmationDialog("移除 \(workspace.name)？", isPresented: $confirmRemove) {
            Button("Remove Side Gate", role: .destructive) { Task { await store.removeSideGate(workspace) } }
        } message: {
            Text("只停止及撤銷呢個 Side Gate。Folder、Main Gate 分享及 Passcode Protection 保留。")
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MCP Connection 配對碼").font(.headline)
                Spacer()
                if let count = status?.tokenCount, count > 0 {
                    Text("已授權 \(count) 個連線").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let pairing = store.pairingCodes[workspace.id] {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(ceil(pairing.expiresAt.timeIntervalSince(context.date))))
                    if remaining > 0 {
                        HStack {
                            Text(pairing.value)
                                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy Code", systemImage: "doc.on.doc") { store.copyPairingCode(workspace) }
                        }
                        Text("一次性使用，\(remaining / 60):\(String(format: "%02d", remaining % 60)) 後過期")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("配對碼已過期，可以產生新碼。")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(status?.pairingActive == true
                     ? "現有配對碼無法重新顯示；可喺呢度產生新碼。"
                     : "首次建立 MCP Connection 時需要一次性配對碼。")
                    .foregroundStyle(.secondary)
            }

            Button("產生新配對碼", systemImage: "arrow.clockwise") {
                Task { await store.generatePairingCode(workspace) }
            }
            .disabled(working || store.diagnostics[workspace.id]?.isUsable != true)
            Text("新碼會令舊碼即時失效；毋須重啟 Bridge 或 Tunnel。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

}
