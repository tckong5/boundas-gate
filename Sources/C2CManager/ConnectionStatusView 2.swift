import SwiftUI

struct ConnectionStatusView: View {
    @ObservedObject var store: WorkspaceStore
    let workspace: WorkspaceRecord
    let rebuild: () -> Void
    @State private var connectorURL = ""

    private var status: WorkspaceStatus? { store.statuses[workspace.id] }
    private var result: ConnectionDiagnostics? { store.diagnostics[workspace.id] }
    private var checking: Bool { store.checkingConnections.contains(workspace.id) }
    private var busy: Bool { store.busy[workspace.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("連線診斷").font(.headline)
                Spacer()
                if checking {
                    ProgressView().controlSize(.small)
                    Text("檢查中").foregroundStyle(.secondary)
                } else {
                    Label(result?.isUsable == true ? "公開連線可用" : "公開連線未就緒",
                          systemImage: result?.isUsable == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(result?.isUsable == true ? Color.green : Color.orange)
                }
            }
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
            Button("檢查連線", systemImage: "stethoscope") {
                Task { await store.diagnoseConnection(workspace) }
            }
            .disabled(busy || checking)
            if status?.running == true && result?.isUsable != true && !checking {
                Text("程序運行唔代表公開連線可用。請重建連線，再用新 MCP URL 更新 ChatGPT connector。")
                    .font(.callout).foregroundStyle(.orange)
                Button("重建連線…", systemImage: "arrow.clockwise", action: rebuild).disabled(busy)
            }

            Divider()
            Text("ChatGPT connector 設定記錄").font(.headline)
            connectorState
            if let previous = workspace.previousMCPURL, previous != status?.mcpURL {
                Text("上次 URL：\(previous)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("貼上 ChatGPT 目前嘅 Server URL，方便比較。App 無法直接讀取 ChatGPT 設定；連線檢查亦唔代表 OAuth 配對已完成。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("https://…trycloudflare.com/mcp", text: $connectorURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.setConnectorURL(workspace, to: connectorURL) }
            HStack {
                Button("儲存設定記錄") { store.setConnectorURL(workspace, to: connectorURL) }
                    .disabled(connectorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                Button("Open ChatGPT") { store.openChatGPT() }
            }
            Button("我已更新為現時 URL") { store.confirmConnectorUpdated(workspace) }
                .disabled(result?.isUsable != true || busy)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { connectorURL = workspace.configuredMCPURL ?? "" }
        .onChange(of: workspace.id) { _, _ in connectorURL = workspace.configuredMCPURL ?? "" }
        .onChange(of: workspace.configuredMCPURL) { _, value in connectorURL = value ?? "" }
    }

    @ViewBuilder private var connectorState: some View {
        switch workspace.connectorState(currentURL: status?.mcpURL) {
        case .unconfirmed:
            Label("ChatGPT Server URL 未確認", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .matches:
            Label("用戶記錄同現時 URL 一致", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .needsUpdate:
            Label("URL 已改變，需要更新 ChatGPT connector", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
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
