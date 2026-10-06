import SwiftUI

struct ConnectionStatusView: View {
    @ObservedObject var store: WorkspaceStore
    let workspace: WorkspaceRecord
    @State private var connectorURL = ""

    private var status: WorkspaceStatus? { store.statuses[workspace.id] }
    private var result: ConnectionDiagnostics? { store.diagnostics[workspace.id] }
    private var checking: Bool { store.checkingConnections.contains(workspace.id) }
    private var busy: Bool { store.busy[workspace.id] != nil }
    private var guidance: ConnectionGuidance {
        .make(workspace: workspace, status: status, diagnostics: result, checking: checking || busy,
              folderExists: FileManager.default.fileExists(atPath: workspace.path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if checking || busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: guidance.needsAttention ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(guidance.needsAttention ? Color.orange : Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(guidance.title).font(.title3.bold())
                    Text(guidance.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(guidance.button) {
                switch guidance.action {
                case .chooseFolder: store.addFolder()
                case .check: Task { await store.diagnoseConnection(workspace) }
                case .repair, .setup: store.guidedWorkspaceID = workspace.id
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || checking)

            DisclosureGroup("連線詳細資料") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(workspace.c2cID)\(status?.port.map { " · Port \($0)" } ?? "")")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    row("本機 Bridge", result?.bridge)
                    row("本機 MCP / OAuth", result?.localMCP)
                    row("公開端點", result?.publicEndpoint)
                    row("公開 MCP / OAuth", result?.publicMCP)
                    row("Bridge / Tunnel URL", result?.address)
                    if let result {
                        Text("上次檢查：\(result.checkedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let reason = status?.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("重新檢查") { Task { await store.diagnoseConnection(workspace) } }.disabled(busy || checking)
                        Button("複製求助資料") { store.copySupportReport(workspace) }
                    }
                    Divider()
                    Text("ChatGPT 地址記錄（選填）").font(.headline)
                    Text("呢個係你確認過嘅設定記錄；App 唔會直接讀取 ChatGPT 設定。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let previous = workspace.previousMCPURL, previous != status?.mcpURL {
                        Text("上次地址：\(previous)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    TextField("貼上 ChatGPT 入面嘅 Server URL", text: $connectorURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.setConnectorURL(workspace, to: connectorURL) }
                    Button("儲存地址記錄") { store.setConnectorURL(workspace, to: connectorURL) }
                        .disabled(connectorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
                .padding(.top, 10)
            }
            .font(.callout)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: Binding(get: { store.guidedWorkspaceID == workspace.id }, set: { if !$0 { store.guidedWorkspaceID = nil } })) {
            ConnectionRepairGuide(store: store, workspace: workspace)
        }
        .onAppear { connectorURL = workspace.configuredMCPURL ?? "" }
        .onChange(of: workspace.id) { _, _ in connectorURL = workspace.configuredMCPURL ?? "" }
        .onChange(of: workspace.configuredMCPURL) { _, value in connectorURL = value ?? "" }
    }

    private func row(_ title: String, _ check: ConnectionCheck?) -> some View {
        let state = check?.state ?? .notChecked
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: state == .passed ? "checkmark.circle.fill" : state == .failed ? "xmark.circle.fill" : "circle.dashed")
                .foregroundStyle(state == .passed ? Color.green : state == .failed ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold())
                Text(check?.detail ?? "未檢查").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
