import SwiftUI

struct TailscaleSetup: Decodable {
    let state: String
    let hostname: String?
    let message: String
    var ready: Bool { state == "ready" }
}

struct StableConnectionView: View {
    @ObservedObject var store: WorkspaceStore
    let workspace: WorkspaceRecord
    @Environment(\.dismiss) private var dismiss
    @State private var setup: TailscaleSetup?
    @State private var checking = false
    @State private var enabling = false
    @State private var failure: String?
    @State private var approvalURL: URL?
    @State private var enabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("設定固定連線地址").font(.title2.bold())
                Spacer()
                Button("關閉") { dismiss() }.disabled(enabling)
            }
            Text(workspace.name).foregroundStyle(.secondary)
            Text("使用 Tailscale Funnel，重新啟動後可以沿用同一個地址。首次轉用要喺 ChatGPT 設定一次新地址。")
            Text("你需要免費嘅 Tailscale 個人帳戶。每個 Folder 暫時仍然需要獨立 ChatGPT 連線。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            if checking || enabling { ProgressView(enabling ? "正在設定固定地址…" : "正在檢查 Tailscale…") }
            if let setup {
                Label(setup.message, systemImage: setup.ready ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(setup.ready ? Color.green : Color.secondary)
                if let hostname = setup.hostname {
                    Text("https://\(hostname)/c2c/\(workspace.c2cID)/mcp")
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                if !setup.ready {
                    HStack {
                        Link("下載 Tailscale", destination: URL(string: "https://tailscale.com/download/mac")!)
                        Button("開啟 Tailscale") { store.openTailscale() }
                    }
                    Text("安裝後，開啟 Tailscale 並登入。完成後返嚟撳「重新檢查」。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let approvalURL {
                Link("開啟 Tailscale 授權頁面", destination: approvalURL)
                Text("喺頁面允許 HTTPS／Funnel 後，返嚟重試。")
            }
            if enabled {
                Label("固定地址已建立", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("下一步：設定 ChatGPT") {
                    dismiss()
                    // Open the next sheet after this sheet has dismissed.
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        store.guidedWorkspaceID = workspace.id
                    }
                }.buttonStyle(.borderedProminent)
            } else {
                Text("啟用會短暫停止呢個 Folder 嘅現有連線，並建立公開 HTTPS 入口。讀取檔案仍然要通過 C2C 嘅 OAuth 配對授權。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("重新檢查") { check() }.disabled(checking || enabling)
                    Button("啟用固定地址") {
                        enabling = true
                        failure = nil
                        approvalURL = nil
                        Task {
                            if let error = await store.enableStableConnection(workspace) {
                                failure = error
                                approvalURL = Self.approvalLink(in: error)
                            } else { enabled = true }
                            enabling = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(setup?.ready != true || checking || enabling || store.busy[workspace.id] != nil)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24).frame(width: 620, height: 540)
        .interactiveDismissDisabled(enabling)
        .onAppear { check() }
    }

    private func check() {
        checking = true
        Task {
            do { setup = try await C2CClient().tailscaleSetup(); failure = nil }
            catch { failure = error.localizedDescription }
            checking = false
        }
    }

    static func approvalLink(in message: String) -> URL? {
        guard let range = message.range(of: #"https://login\.tailscale\.com/[^\s<>"']+"#, options: .regularExpression),
              let url = URL(string: String(message[range])), url.host == "login.tailscale.com" else { return nil }
        return url
    }
}
