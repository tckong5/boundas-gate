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
        .disabled(gateway.working || gateway.visiblyChecking
                  )
        if gateway.statusConfirmed && (gateway.status?.running == true || gateway.status?.desiredRunning == true) {
            if gateway.status?.running == true && gateway.status?.state != "unknown" {
                Button("重啟共用連線") {
                    store.selectedID = SharedGatewayStore.selectionID
                    showManager()
                    Task { await gateway.restart() }
                }.disabled(gateway.working || gateway.visiblyChecking)
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
                        ForEach(store.mainGateWorkspaces) { workspace in
                            HStack(spacing: 10) {
                                mainFolderLabel(workspace)
                                Spacer(minLength: 8)
                                FolderPasscodeButton(
                                    gateway: gateway, workspace: workspace,
                                    configurationChanged: sharedSelection != savedSharedSelection
                                )
                            }
                            .padding(.vertical, 2).tag(workspace.id)
                            .foregroundStyle(.primary)
                            .background(SidebarSelectionAppearance())
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(mainFolderSelection == workspace.id ? Color.primary.opacity(0.08) : Color.clear)
                                    .padding(.horizontal, 10)
                            )
                            .contextMenu {
                                Button("Rename") { beginRename(workspace) }
                                Button("Copy Path") { store.copyText(workspace.path) }
                                Divider()
                                Button("Add to Side Gates (Keep Both)") { store.addToSideGates(workspace) }
                                    .disabled(workspace.belongsToSideGates || workspace.sideGateRemovalState != nil || store.busy[workspace.id] != nil)
                                Button("Move to Side Gate") {
                                    Task { _ = await store.moveToSideGates(workspace) }
                                }
                                .disabled(gateway.working || workspace.sideGateRemovalState != nil || store.busy[workspace.id] != nil)
                                Divider()
                                Button("Remove Folder", role: .destructive) { store.removeFolder(workspace) }
                                    .disabled(workspace.belongsToSideGates)
                            }
                        }
                        .onMove { store.moveFolders(from: $0, to: $1, side: false) }
                    }
                    .listStyle(.sidebar)
                    .onKeyPress(.return) {
                        guard renamingFolderID == nil,
                              let workspace = store.mainGateWorkspaces.first(where: { $0.id == mainFolderSelection }) else {
                            return .ignored
                        }
                        beginRename(workspace)
                        return .handled
                    }
                    .overlay {
                        if store.mainGateWorkspaces.isEmpty { SidebarEmptyFolders() }
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
                                sidebarFolderLabel(workspace) {
                                    SideGateLifecycleDot(store: store, gateway: store.sideGateway(for: workspace), workspace: workspace)
                                }
                                Spacer(minLength: 8)
                                FolderPasscodeButton(gateway: store.sideGateway(for: workspace), workspace: workspace, configurationChanged: false)
                                    .disabled(workspace.sideGateRemovalState != nil || store.busy[workspace.id] != nil)
                            }
                            .padding(.vertical, 2).tag(workspace.id)
                            .foregroundStyle(.primary)
                            .background(SidebarSelectionAppearance())
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(store.selectedID == workspace.id ? Color.primary.opacity(0.08) : Color.clear)
                                    .padding(.horizontal, 10)
                            )
                            .contextMenu {
                                Button("Rename") { beginRename(workspace) }
                                Button("Copy Path") { store.copyText(workspace.path) }
                            }
                        }
                        .onMove { store.moveFolders(from: $0, to: $1, side: true) }
                    }
                    .listStyle(.sidebar)
                    .onKeyPress(.return) {
                        guard renamingFolderID == nil,
                              let workspace = store.sideGateWorkspaces.first(where: { $0.id == store.selectedID }) else { return .ignored }
                        beginRename(workspace)
                        return .handled
                    }
                    .overlay {
                        if store.sideGateWorkspaces.isEmpty { SidebarEmptyFolders() }
                    }
                }
            }
            .toolbar {
                Button("重新檢查", systemImage: "arrow.clockwise") {
                    Task { await gateway.refresh() }
                    Task { await store.refreshAll() }
                }.disabled(gateway.working || gateway.visiblyChecking)
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
            if gateMode == .main || id != renamingFolderID { cancelRename() }
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
            let mainFolders = records.filter(\.belongsToMainGate)
            sharedSelection.formIntersection(Set(mainFolders.map { $0.id.uuidString.lowercased() }))
            if store.selectedID == SharedGatewayStore.selectionID, !previous.contains(where: \.belongsToMainGate), let first = mainFolders.first {
                sharedSelection.insert(first.id.uuidString.lowercased())
            }
            if let id = mainFolderSelection, !mainFolders.contains(where: { $0.id == id }) { mainFolderSelection = nil }
            if let id = sideFolderSelection, !records.contains(where: { $0.id == id && $0.belongsToSideGates }) { sideFolderSelection = nil }
            if let id = renamingFolderID, !ids.contains(id) { cancelRename() }
        }
    }

    private func mainFolderLabel(_ workspace: WorkspaceRecord) -> some View {
        sidebarFolderLabel(workspace) {
            FolderSharingDot(isShared: sharedSelection.contains(workspace.id.uuidString.lowercased()),
                             color: sharedSelection.contains(workspace.id.uuidString.lowercased())
                                ? (gateway.sidebarConnectionReady ? .green : .orange) : .secondary.opacity(0.35)) {
                let id = workspace.id.uuidString.lowercased()
                if sharedSelection.contains(id) { sharedSelection.remove(id) }
                else { sharedSelection.insert(id) }
            }
            .disabled(gateway.working || !gateway.statusConfirmed || store.busy[workspace.id] != nil)
            .help(sharedSelection.contains(workspace.id.uuidString.lowercased()) ? "Stop sharing through Main Gate" : "Share through Main Gate")
            .accessibilityLabel("Main Gate access for \(workspace.name)")
            .accessibilityValue(sharedSelection.contains(workspace.id.uuidString.lowercased()) ? "On" : "Off")
        }
    }

    private func sidebarFolderLabel<Indicator: View>(_ workspace: WorkspaceRecord, @ViewBuilder indicator: () -> Indicator) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
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
            }
            .padding(.leading, 30)
            .overlay(alignment: .leading) {
                indicator()
            }
            Text(sidebarPath(workspace.path))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head).help(workspace.path)
        }
    }

    private func beginRename(_ workspace: WorkspaceRecord) {
        if gateMode == .main { mainFolderSelection = workspace.id }
        else { store.selectedID = workspace.id }
        renamedFolderName = workspace.name
        renamingFolderID = workspace.id
    }

    private func cancelRename() {
        renamingFolderID = nil
        renameFocus = nil
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

private struct FolderSharingDot: View {
    let isShared: Bool
    var color: Color? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.primary.opacity(hovering && isEnabled ? 0.09 : 0))
                    .frame(width: 20, height: 20)
                Circle().fill(color ?? (isShared ? Color.green : Color.secondary.opacity(0.35)))
                    .frame(width: 7, height: 7)
                    .scaleEffect(hovering && isEnabled ? 1.15 : 1)
            }
            .frame(width: 20, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
                if isEnabled { NSCursor.pointingHand.set() }
            case .ended:
                hovering = false
                NSCursor.arrow.set()
            }
        }
        .onDisappear { if hovering { NSCursor.arrow.set() } }
    }
}

private struct SideGateLifecycleDot: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gateway: SharedGatewayStore
    let workspace: WorkspaceRecord

    private var running: Bool { gateway.status?.running == true }
    private var unavailable: Bool {
        !workspace.canOperateSideGate || store.busy[workspace.id] != nil || gateway.working || gateway.reconnecting
            || !gateway.statusConfirmed || gateway.status?.state == "unknown" || gateway.status?.running == nil
    }
    private var color: Color {
        if workspace.sideGateRemovalState != nil { return .orange }
        if gateway.sidebarConnectionReady { return .green }
        return running ? .orange : .secondary.opacity(0.35)
    }
    var body: some View {
        FolderSharingDot(isShared: running, color: color) {
            Task { await store.toggleSideGate(workspace) }
        }
        .disabled(unavailable)
        .help(running ? "Close Side Gate" : "Open Side Gate")
        .accessibilityLabel("\(workspace.name): \(running ? "Close Side Gate" : "Open Side Gate")")
        .accessibilityValue(running ? "Open" : "Closed")
        .task {
            if workspace.canOperateSideGate, !gateway.statusConfirmed, !gateway.working { await gateway.refresh(background: true) }
        }
    }
}

private extension SharedGatewayStore {
    // Sidebar completion includes AI authorization; Gate runtime health remains
    // independent and can still be Open with zero MCP Connections.
    var sidebarConnectionReady: Bool {
        GateConnectionJourney.make(status: status, diagnostics: diagnostics, confirmed: statusConfirmed,
                                   busy: false, usable: usable).isReady
    }
}

/// Keep native List selection and keyboard handling, with a neutral row highlight.
private struct SidebarSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ nsView: SelectionView, context: Context) {
        nsView.applyAppearance()
    }

    final class SelectionView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyAppearance()
        }

        func applyAppearance() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct SidebarEmptyFolders: View {
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 6) {
                Text("Add your first Folder")
                    .font(.system(size: 13, weight: .medium))
                Text("Choose a folder to share through Main Gate.")
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
