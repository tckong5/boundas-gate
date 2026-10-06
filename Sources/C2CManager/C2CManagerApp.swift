import AppKit
import SwiftUI

@main
struct C2CManagerApp: App {
    @NSApplicationDelegateAdaptor(ManagerAppDelegate.self) private var appDelegate
    @StateObject private var store = WorkspaceStore()

    var body: some Scene {
        Window("Boundas Gate", id: "manager") {
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
        Text("共用連線：\(gateway.connectionTitle)")
        Divider()
        Button("共用 ChatGPT 連線…") {
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
                  || ([.stopped, .needsRepair].contains(gateway.connectionState) && gateway.status?.roots.isEmpty != false))
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
        Text("獨立連線：\(store.healthyConnectionCount) 個就緒")
        if store.workspaces.isEmpty {
            Text("尚未加入 Workspace")
        }
        ForEach(store.workspaces) { workspace in
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
                Button("Manage Workspace…") {
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
        Button("Add Workspace by Path…", systemImage: "text.cursor") {
            showManager()
            store.showingAddPath = true
        }
        Button("Start All Independent Connections") {
            Task {
                await store.startAll()
                if let workspace = store.workspaces.first(where: { store.pairingCodes[$0.id] != nil }) {
                    store.selectedID = workspace.id
                    showManager()
                }
            }
        }
            .disabled(store.workspaces.isEmpty)
        Button("Stop All") { Task { await store.stopAll() } }
            .disabled(store.runningCount == 0 && gateway.status?.running != true)
        Divider()
        Button("Manage Workspaces…") { showManager() }
        Button("Open ChatGPT") { store.openChatGPT() }
        Button("Quit Boundas Gate") { NSApp.terminate(nil) }
    }

    private func showManager() {
        openWindow(id: "manager")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ManagerWindow: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gateway: SharedGatewayStore
    let appDelegate: ManagerAppDelegate
    @Environment(\.openWindow) private var openWindow

    init(store: WorkspaceStore, appDelegate: ManagerAppDelegate) {
        self.store = store
        self.gateway = store.gateway
        self.appDelegate = appDelegate
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedID) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("共用 ChatGPT 連線", systemImage: "folder.badge.person.crop")
                    Text(gateway.connectionTitle).font(.caption)
                        .foregroundStyle(gateway.usable ? Color.green : Color.secondary)
                }.padding(.vertical, 4).tag(SharedGatewayStore.selectionID)
                Section("獨立 Folder 連線") {
                ForEach(store.workspaces) { workspace in
                    HStack(spacing: 10) {
                        Image(systemName: store.statuses[workspace.id]?.running == true ? "circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(store.diagnostics[workspace.id]?.isUsable == true ? Color.green : store.statuses[workspace.id]?.running == true ? Color.orange : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workspace.name).fontWeight(.medium)
                            Text(workspace.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(workspace.id)
                    .padding(.vertical, 4)
                }
                }
            }
            .navigationTitle("Workspaces")
            .toolbar {
                Button("Add Folders", systemImage: "plus") { store.addFolder() }
                    .help("按住 ⌘ 可一次選多個資料夾。")
                Button("Add by Path", systemImage: "text.cursor") { store.showingAddPath = true }
                Button("重新檢查", systemImage: "arrow.clockwise") {
                    Task { await gateway.refresh() }
                    Task { await store.refreshAll() }
                }.disabled(gateway.working || gateway.checking)
            }
            .frame(minWidth: 270)
        } detail: {
            if store.selectedID == SharedGatewayStore.selectionID {
                SharedGatewayView(store: store, gateway: store.gateway)
            } else if let workspace = store.workspaces.first(where: { $0.id == store.selectedID }) {
                WorkspaceDetail(store: store, workspace: workspace).id(workspace.id)
            } else {
                ContentUnavailableView("選擇一個 Workspace", systemImage: "folder", description: Text("加入任何 folder，然後獨立管理佢嘅 C2C 連線。"))
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
        }
    }
}

private struct AddPathSheet: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Workspace by Path").font(.title2.bold())
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
                Button("加入 Workspace", action: add)
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

                Text("呢頁管理獨立 Folder connector。共用 connector 嘅 Folder 授權，請喺「共用 ChatGPT 連線」管理。")
                    .font(.callout).foregroundStyle(.secondary)
                ConnectionStatusView(store: store, workspace: workspace)

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
                    Text("Workspace").font(.headline)
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
                        Button("Remove Workspace", role: .destructive) { confirmRemove = true }
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
            Button("移除 Workspace", role: .destructive) { Task { await store.remove(workspace) } }
        } message: {
            Text("會撤銷已授權連線，並停止運行中嘅 Bridge 同 Tunnel。Folder 入面嘅檔案不會刪除。")
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ChatGPT 配對碼").font(.headline)
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
                     : "首次加入 ChatGPT connector 時需要一次性配對碼。")
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
