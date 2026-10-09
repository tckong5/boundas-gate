import SwiftUI

struct WorkspaceDetail: View {
    @ObservedObject var store: WorkspaceStore
    let workspace: WorkspaceRecord
    @ObservedObject var gateway: SharedGatewayStore
    @State private var confirmRemove = false
    @State private var showAdvanced = false
    @State private var renaming = false
    @State private var proposedName = ""
    @FocusState private var renameFocused: Bool

    init(store: WorkspaceStore, workspace: WorkspaceRecord) {
        self.store = store
        self.workspace = workspace
        self.gateway = store.sideGateway(for: workspace)
    }

    private var working: Bool { store.busy[workspace.id] != nil || gateway.working || gateway.reconnecting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        if renaming {
                            TextField("Folder name", text: $proposedName)
                                .font(.title2.weight(.semibold)).textFieldStyle(.plain)
                                .focused($renameFocused)
                                .onSubmit(saveName)
                                .onExitCommand { renaming = false }
                        } else {
                            Text(workspace.name).font(.title2.weight(.semibold))
                        }
                        Text(workspace.path).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("Independent Side Gate for this Folder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    FolderPasscodeButton(gateway: gateway, workspace: workspace, configurationChanged: false)
                    Menu {
                        Button("Rename") { beginRename() }
                        Button("Recheck") { Task { await gateway.refresh() } }
                        Button("Advanced…") { showAdvanced = true }
                        Divider()
                        Button("Remove Side Gate…", role: .destructive) { confirmRemove = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(working)
                }
                .contextMenu { Button("Rename") { beginRename() } }
                if !FileManager.default.fileExists(atPath: workspace.path) {
                    Text("Folder is unavailable on this Mac.").font(.callout).foregroundStyle(.orange)
                }
                if let removal = workspace.sideGateRemovalState {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(removal == .removing ? "Removing Side Gate…" : "Side Gate removal needs attention.")
                            .font(.headline).foregroundStyle(.orange)
                        if let error = workspace.sideGateRemovalError {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                        }
                        if removal == .failed {
                            Button("Retry") { Task { await store.removeSideGate(workspace) } }.disabled(working)
                        }
                    }
                } else {
                    GateConnectionContent(gateway: gateway, selected: .constant([]), context: .side(workspace), advanced: $showAdvanced)
                }
                Divider()
                HStack(spacing: 10) {
                    Button("Open Folder") { store.openFolder(workspace) }
                    Button("Open Logs") { store.openLogs(workspace) }
                }
                .controlSize(.small)
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Side Gate")
        .task { await gateway.refresh() }
        .confirmationDialog("Remove Side Gate", isPresented: $confirmRemove) {
            Button("Remove Side Gate", role: .destructive) { Task { await store.removeSideGate(workspace) } }
        } message: {
            Text("Only this Side Gate will be stopped and revoked. The Folder, Main Gate sharing, and Passcode Protection will remain.")
        }
    }

    private func beginRename() {
        proposedName = workspace.name
        renaming = true
        renameFocused = true
    }

    private func saveName() {
        store.rename(workspace, to: proposedName)
        renaming = false
    }
}
