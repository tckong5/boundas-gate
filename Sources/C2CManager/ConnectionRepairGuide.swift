import SwiftUI

struct ConnectionRepairGuide: View {
    private enum Stage { case prepare, repairing, chatGPT, test, complete, failed }
    @ObservedObject var store: WorkspaceStore
    let workspace: WorkspaceRecord
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .prepare
    @State private var progress = ConnectionSetupProgress()
    @State private var notice: String?
    @State private var stillCannotConnect = false
    @State private var supportCopied = false

    private var status: WorkspaceStatus? { store.statuses[workspace.id] }
    private var usable: Bool { store.diagnostics[workspace.id]?.isUsable == true }
    private var busy: Bool { store.busy[workspace.id] != nil }
    private var isWorking: Bool { stage == .repairing || busy }
    private var currentAddressMatches: Bool { progress.address == EndpointAddress.mcpURL(status?.mcpURL) }
    private var reuseConnection: Bool {
        workspace.provider == .tailscale && workspace.connectorState(currentURL: status?.mcpURL) == .matches
    }
    private var testPrompt: String {
        "請用我剛加入嘅「\(workspace.name)」連線，只列出 Folder 最上層嘅檔案名稱，唔好修改任何檔案。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("連接 ChatGPT").font(.title2.bold())
                    Text(workspace.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button(stage == .complete ? "完成" : "稍後再做") { dismiss() }.disabled(isWorking)
            }
            HStack(spacing: 12) {
                stepLabel(1, "Mac 連線", done: stage == .chatGPT || stage == .test || stage == .complete)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                stepLabel(2, "ChatGPT 設定", done: stage == .test || stage == .complete)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                stepLabel(3, "試讀檔案", done: stage == .complete)
            }
            .font(.callout)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let notice {
                        Label(notice, systemImage: "info.circle").foregroundStyle(.orange)
                    }
                    switch stage {
                    case .prepare: prepareStep
                    case .repairing:
                        VStack(alignment: .leading, spacing: 12) {
                            ProgressView()
                            Text("正在建立連線，請稍等…").font(.headline)
                            Text("App 會重新啟動連線，並檢查新地址可唔可以使用。").foregroundStyle(.secondary)
                        }
                    case .chatGPT: chatGPTStep
                    case .test: testStep
                    case .complete:
                        Label("你已確認 ChatGPT 可以讀取呢個 Folder", systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(.green)
                        Text("地址記錄已儲存。之後連線地址改變，App 會再提示你更新 ChatGPT 設定。")
                        Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
                    case .failed: failureStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .padding(24)
        .frame(width: 620, height: 620)
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            progress.observe(status?.mcpURL)
            if usable { advanceFromConnection() }
        }
        .onChange(of: status?.mcpURL) { _, address in
            let previous = progress.address
            progress.observe(address)
            guard previous != progress.address, stage == .chatGPT || stage == .test || stage == .complete else { return }
            stage = .chatGPT
            stillCannotConnect = false
            notice = "連線地址改咗，請重新複製地址，再完成 ChatGPT 設定。"
        }
    }

    private var prepareStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("先由 App 處理 Mac 嗰邊").font(.headline)
            Text("App 會啟動或重新建立「\(workspace.name)」嘅連線，準備一個俾 ChatGPT 使用嘅地址。")
            Text(workspace.provider == .tailscale
                 ? "現有連線會短暫中斷。Tailscale 主機名稱保持不變時，修復後可以沿用 ChatGPT 現有連線。"
                 : "現有連線可能短暫中斷，地址亦可能改變。完成後，下一頁會帶你設定 ChatGPT。")
                .foregroundStyle(.secondary)
            Button("開始修復連線", systemImage: "wand.and.stars") { repair() }
                .buttonStyle(.borderedProminent).disabled(busy)
        }
    }

    private var chatGPTStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mac 嗰邊已準備好，下一步喺 ChatGPT 設定").font(.headline)
            Text("呢一步需要你喺 ChatGPT 完成。照住下面做，完成後返嚟撳「下一步」。")
                .foregroundStyle(.secondary)
            if !usable {
                Label("連線暫時未能使用。請先重新檢查，唔好貼上未確認嘅地址。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("重新檢查連線") { recheck() }.disabled(busy)
            }
            instruction(1, "複製連線地址", "撳下面個掣，地址會自動複製，亦會開啟 ChatGPT 嘅 Plugins 頁面。")
            Text(progress.address ?? "等待連線地址")
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Button(progress.addressCopied ? "重新複製地址並開啟 ChatGPT" : "複製地址並開啟 ChatGPT", systemImage: "arrow.up.right.square") {
                store.copyURL(workspace)
                progress.markAddressCopied(status?.mcpURL)
                store.openChatGPT()
            }
            .buttonStyle(.borderedProminent).disabled(!usable || !currentAddressMatches || busy)
            if progress.addressCopied { Label("地址已複製", systemImage: "checkmark").font(.caption).foregroundStyle(.green) }
            instruction(2, "喺 ChatGPT 加入呢個 Folder 嘅連線", "喺 Plugins 頁面撳 ＋。名稱填「\(workspace.name)」；喺 Connection 嘅 MCP server URL／Server URL 欄貼上啱啱複製嘅地址。Authentication（認證方式）揀 OAuth，再撳 Create（建立）。")
            Text("如果係修復舊連線，亦請用新地址建立連線，避免沿用舊設定。測試成功後，可以移除呢個 Folder 嗰條舊連線。")
                .font(.callout).foregroundStyle(.secondary)
            pairingHelp
            DisclosureGroup("搵唔到新增連線嘅選項？") {
                Text("開啟 ChatGPT Settings（設定）→ Security and login（安全與登入）→ Developer mode（開發者模式）。如果呢個選項都冇，可能受帳戶或公司設定限制，請向帳戶管理員查詢。")
                    .font(.callout).padding(.top, 8)
            }
            Link("OpenAI 官方設定圖文教學", destination: URL(string: "https://developers.openai.com/plugins/deploy/connect-chatgpt")!)
                .font(.caption)
            Divider()
            Button("我已完成 ChatGPT 設定，下一步") {
                guard progress.confirmSettings(status?.mcpURL) else { return }
                store.confirmConnectorUpdated(workspace)
                notice = nil
                stage = .test
            }
            .buttonStyle(.borderedProminent)
            .disabled(!usable || !currentAddressMatches || !progress.addressCopied || busy)
        }
    }

    private var pairingHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ChatGPT 要求配對碼時").font(.subheadline.bold())
            Text("撳「產生配對碼」，再將碼填入 ChatGPT 開啟嘅授權頁面。唔需要配對碼就可以繼續下一步。")
                .font(.callout).foregroundStyle(.secondary)
            if let pairing = store.pairingCodes[workspace.id] {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(ceil(pairing.expiresAt.timeIntervalSince(context.date))))
                    if remaining > 0 {
                        HStack {
                            Text(pairing.value).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                            Button("複製配對碼") { store.copyPairingCode(workspace) }
                        }
                        Text("\(remaining / 60):\(String(format: "%02d", remaining % 60)) 後過期；過期可以重新產生。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("配對碼已過期，請重新產生。").font(.callout) }
                }
            }
            Button("產生新配對碼") { Task { await store.generatePairingCode(workspace) } }
                .disabled(!usable || busy)
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("最後，試一次讀取檔案").font(.headline)
            if reuseConnection { Text("固定地址冇變，可以沿用現有 ChatGPT 連線，唔需要重新新增。") }
            instruction(1, "喺 ChatGPT 開新對話", "喺工具選單揀返「\(workspace.name)」連線。如果你用 Work，可以輸入 @ 再揀返呢個連線。")
            instruction(2, "貼上測試句子", "撳下面個掣複製，再貼到 ChatGPT 並送出。")
            Text(testPrompt).textSelection(.enabled)
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Button(progress.testPromptCopied ? "再複製測試句子" : "複製測試句子") {
                store.copyText(testPrompt)
                progress.markTestPromptCopied()
            }.disabled(!usable || !currentAddressMatches)
            Text("ChatGPT 成功列出呢個 Folder 嘅檔案名稱，就代表你已經可以開始用。")
                .foregroundStyle(.secondary)
            Button("ChatGPT 已成功列出檔案") {
                stage = .complete
            }
            .buttonStyle(.borderedProminent)
            .disabled(!progress.canConfirmTest || !usable || !currentAddressMatches || busy)
            Button("仍然連唔到") { stillCannotConnect = true }
            if stillCannotConnect || !usable {
                Label("請確認新對話揀咗新連線。舊對話可能仍然用緊之前嘅連線。", systemImage: "info.circle")
                Button("返回 ChatGPT 設定引導") { stage = .chatGPT }
                Button("重新檢查 Mac 連線") { recheck() }.disabled(busy)
                supportButton
            }
        }
    }

    private var failureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("今次未能完成連線", systemImage: "exclamationmark.circle.fill").font(.headline).foregroundStyle(.orange)
            Text("先確認 Mac 可以正常上網，再撳「重新檢查」。如果仍然唔得，複製求助資料，連同 ChatGPT 嘅錯誤畫面交俾幫你設定嘅人。")
            Button("重新檢查") { recheck() }.buttonStyle(.borderedProminent).disabled(busy)
            Button("再試修復連線") { stage = .prepare }.disabled(busy)
            supportButton
        }
    }

    private var supportButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(supportCopied ? "求助資料已複製" : "複製求助資料") {
                store.copySupportReport(workspace)
                supportCopied = true
            }
            Text("只會複製連線檢查結果；唔會自動傳送。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func repair() {
        stage = .repairing
        notice = nil
        Task {
            let success = await store.repairConnection(workspace)
            progress.observe(status?.mcpURL)
            if success { advanceFromConnection() } else { stage = .failed }
        }
    }

    private func recheck() {
        stage = .repairing
        Task {
            await store.diagnoseConnection(workspace)
            progress.observe(status?.mcpURL)
            if usable { advanceFromConnection() } else { stage = .failed }
        }
    }

    private func advanceFromConnection() {
        if reuseConnection {
            progress.markAddressCopied(status?.mcpURL)
            _ = progress.confirmSettings(status?.mcpURL)
        }
        stage = progress.settingsConfirmed ? .test : .chatGPT
    }

    private func instruction(_ number: Int, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(number). \(title)").font(.subheadline.bold())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepLabel(_ number: Int, _ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "\(number).circle")
            .foregroundStyle(done ? Color.green : Color.secondary)
    }
}
