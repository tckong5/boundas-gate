import SwiftUI

struct SharedGatewayView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gateway: SharedGatewayStore
    @State private var selected: Set<String> = []
    @State private var initialized = false
    @State private var showSetup = false
    @State private var confirmRevoke = false
    @State private var testCopied = false
    @State private var showPairing = false
    @State private var showTunnelManagement = false

    private var saved: Set<String> { Set((gateway.status?.roots ?? []).map { $0.sourceID.lowercased() }) }
    private var changed: Bool { selected != saved }
    private var testPrompt: String {
        "請用 Boundas Gate 共用連線，先 call list_workspaces，再分別列出每個已授權 Folder 最上層嘅檔案名稱。唔好修改任何檔案。"
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionControls
                .padding(.horizontal, 28).padding(.vertical, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(store.workspaces) { workspace in
                                Toggle(isOn: Binding(
                                    get: { selected.contains(workspace.id.uuidString.lowercased()) },
                                    set: { enabled in
                                        let id = workspace.id.uuidString.lowercased()
                                        if enabled { selected.insert(id) } else { selected.remove(id) }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(workspace.name).fontWeight(.medium)
                                        Text(saved.contains(workspace.id.uuidString.lowercased()) ? "已分享" : "未分享")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(workspace.path).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle).help(workspace.path)
                                    }
                                }.disabled(gateway.working || !gateway.statusConfirmed)
                            }
                            if changed {
                                Button("儲存變更") {
                                    Task { _ = await gateway.perform("configure", selectedIDs: selected.sorted()) }
                                }.buttonStyle(.borderedProminent).disabled(gateway.working || !gateway.statusConfirmed)
                                Text(gateway.status?.authorizationVersion == 2
                                     ? "儲存後即時更新分享範圍，毋須重新配對。"
                                     : "儲存後取消分享即時生效；套用新版授權後，新增 Folder 毋須重新配對。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    } label: {
                        HStack {
                            Label("Folders", systemImage: "folder")
                            Spacer()
                            Text("已選 \(selected.count) 個").foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("Folder 通行碼（選用）") {
                        folderCodeSettings.padding(.top, 10)
                    }
                    DisclosureGroup("連線詳細資料") {
                        VStack(alignment: .leading, spacing: 10) {
            Button("Manage Tunnel…") { showTunnelManagement = true }
                .buttonStyle(.borderless).controlSize(.small)
                            if let url = gateway.status?.mcpURL {
                                Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            if let message = gateway.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                            if let reason = gateway.status?.reason { Text(reason).foregroundStyle(.secondary).textSelection(.enabled) }
                            Text("固定 HTTPS 地址；檔案存取需要 OAuth 配對。")
                                .foregroundStyle(.secondary)
                        }.font(.callout).padding(.top, 8)
                    }
                    if gateway.usable {
                        DisclosureGroup("ChatGPT 配對／授權", isExpanded: $showPairing) {
                            VStack(alignment: .leading, spacing: 12) {
                                if gateway.status?.addressConfirmed == true {
                                    Label("已記錄 ChatGPT 設定", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                                }
                                if let pairing = gateway.pairing {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        let remaining = max(0, Int(ceil(pairing.expiration.timeIntervalSince(context.date))))
                                        if remaining > 0 {
                                            HStack(spacing: 16) {
                                                Text(pairing.pairingCode).font(.system(.title, design: .monospaced).bold()).textSelection(.enabled)
                                                Button("複製") { gateway.copy(pairing.pairingCode) }
                                            }
                                            Text("目前分享：\((gateway.status?.roots.map(\.name) ?? pairing.roots.map(\.name)).joined(separator: "、"))").font(.callout)
                                            Text(gateway.status?.authorizationVersion == 2
                                                 ? "此配對連接 Boundas Gate；之後確認分享嘅 Folders 亦可讀取。"
                                                 : "請先套用新版授權，新增分享嘅 Folders 先會自動生效。")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text("\(remaining / 60):\(String(format: "%02d", remaining % 60)) 後過期")
                                                .font(.caption).foregroundStyle(.secondary)
                                        } else { Text("配對碼已過期，請重新產生。").foregroundStyle(.orange) }
                                    }
                                }
                                HStack {
                                    Button(gateway.pairing == nil ? "產生配對碼" : "重新產生") { Task { _ = await gateway.perform("pair") } }
                                        .disabled(gateway.working || changed)
                                    if gateway.status?.addressConfirmed != true {
                                        Button("已完成設定") { Task { _ = await gateway.perform("confirm") } }.disabled(gateway.working)
                                    }
                                }
                                Button(testCopied ? "已複製 · 再複製測試句子" : "複製測試句子") { gateway.copy(testPrompt); testCopied = true }
                                DisclosureGroup("設定教學", isExpanded: $showSetup) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("1. 複製 URL，去 ChatGPT 新增連線。")
                                        Text("2. 名稱填 Boundas Gate，貼上 Server URL，選 OAuth。")
                                        Text("3. 授權時輸入配對碼，再貼上測試句子。")
                                        Text(gateway.status?.authorizationVersion == 2
                                             ? "只需配對一次。之後喺 App 勾選並儲存分享清單，原有 Plugin 就會讀取最新範圍。停止分享即時撤銷存取。"
                                             : "請先按「套用新版授權」。升級後，原有 Plugin 會按最新分享清單讀取，毋須重新配對。")
                                            .foregroundStyle(.secondary)
                                    }.font(.callout).padding(.top, 8)
                                }
                                DisclosureGroup("管理授權") {
                                    Button("撤銷全部授權…", role: .destructive) { confirmRevoke = true }
                                        .disabled(gateway.working).padding(.top, 8)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("共用 ChatGPT 連線")
        .sheet(isPresented: $showTunnelManagement) {
            TunnelManagementView(gateway: gateway)
        }
        .onAppear {
            syncSelection()
            showPairing = gateway.status?.tokenCount == 0 || gateway.pairing != nil
        }
        .onChange(of: gateway.status?.tokenCount) { _, count in if count == 0 { showPairing = true } }
        .onChange(of: gateway.pairing?.pairingCode) { _, code in if code != nil { showPairing = true } }
        .onChange(of: gateway.status?.roots) { _, _ in if !initialized { syncSelection() } }
        .onChange(of: store.workspaces) { _, records in selected.formIntersection(Set(records.map { $0.id.uuidString.lowercased() })) }
        .confirmationDialog("撤銷全部共用連線授權？", isPresented: $confirmRevoke) {
            Button("撤銷授權", role: .destructive) { Task { _ = await gateway.perform("revoke") } }
        } message: { Text("現有共用 connector 即時失去存取權。要再用需要重新配對。獨立 Folder connectors 不受影響。") }
    }

    private func syncSelection() {
        guard gateway.status != nil else { return }
        selected = saved
        initialized = true
    }

    private var primaryButtonTitle: String {
        if changed && [.stopped, .needsRepair].contains(gateway.connectionState) {
            return "儲存並開啟共用連線"
        }
        return gateway.connectionState.button
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("共用連線").font(.title.bold())
                    Text("一個 ChatGPT 連線，多個 Folders").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(gateway.connectionTitle, systemImage: gateway.usable ? "checkmark.circle.fill" : "link")
                    .foregroundStyle(gateway.usable ? Color.green : Color.secondary)
                if gateway.working || gateway.checking { ProgressView().controlSize(.small) }
            }
            HStack {
                Button(primaryButtonTitle) { Task { await runPrimaryAction() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(gateway.working || gateway.checking)
                if gateway.statusConfirmed && (gateway.status?.running == true || gateway.status?.desiredRunning == true) {
                    if gateway.status?.running == true && gateway.status?.state != "unknown" {
                        Button("重啟") { Task { await gateway.restart() } }
                            .disabled(gateway.working || gateway.checking || changed)
                    }
                    Button("停止") { Task { _ = await gateway.perform("stop") } }
                        .disabled(gateway.working)
                }
                if ![.checking, .unknown].contains(gateway.connectionState) {
                    Button("重新檢查") { Task { await gateway.refresh() } }
                        .disabled(gateway.working || gateway.checking)
                }
            }
            if gateway.status?.transport == "external" {
                Text("沿用原有 Tailscale 連線及地址。").font(.caption).foregroundStyle(.secondary)
            }
            if gateway.status?.transport == "embedded", let setup = gateway.status?.transportSetup,
               setup.state != "ready" {
                Text(setup.message).font(.callout).foregroundStyle(.secondary)
                HStack {
                    if let url = setup.actionURL {
                        Link(setup.loginURL != nil ? "登入內置連線" : "允許公開連線", destination: url)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("登入內置連線") { Task { _ = await gateway.perform("login") } }
                            .disabled(gateway.working)
                    }
                    Button("登入後重新檢查") { Task { await gateway.refresh() } }
                        .disabled(gateway.working || gateway.checking)
                }
            }
            Toggle("斷線後自動恢復", isOn: Binding(
                get: { gateway.automaticallyReconnects },
                set: { enabled in Task { await gateway.setAutomaticReconnect(enabled) } }
            ))
            .toggleStyle(.checkbox).font(.callout)
            .disabled(gateway.working || !gateway.statusConfirmed)
            .help("App 運行時自動恢復已開啟嘅共用連線；手動停止後唔會自行開啟。")
            if !gateway.connectionHint.isEmpty {
                Text(gateway.connectionHint).font(.caption).foregroundStyle(.secondary)
            }
            if gateway.statusConfirmed && gateway.status?.running == true && gateway.status?.authorizationVersion != 2 {
                Button("套用新版授權") { Task { await gateway.restart() } }
                    .disabled(gateway.working || gateway.checking || changed)
                    .help("重啟共用服務，保留原有 Plugin 授權同固定地址。")
            }
            if let message = gateway.message {
                Text(gateway.userFacingMessage ?? "").font(.caption).foregroundStyle(.orange)
                if let link = StableConnectionView.approvalLink(in: message) {
                    Link("開啟 Tailscale 授權頁面", destination: link)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runPrimaryAction() async {
        switch gateway.connectionState {
        case .checking, .unknown:
            await gateway.refresh()
        case .stopped, .needsRepair:
            if changed {
                guard await gateway.perform("configure", selectedIDs: selected.sorted()) else { return }
            }
            await gateway.repair()
        case .ready:
            gateway.copyURL(openChatGPT: true)
        }
    }

    private var folderCodeSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("預設關閉，只保護已開啟嘅 Folders。用碼解鎖後可讀取最多 30 分鐘。")
                .font(.caption).foregroundStyle(.secondary)
            if gateway.status?.running == false {
                Text("先按上方「開啟共用連線」，就可以產生通行碼。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if (gateway.status?.roots ?? []).contains(where: { $0.codeRequired == true }) {
                Text("首次使用：喺 ChatGPT 連線設定按 Refresh，載入解鎖工具。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if gateway.status?.running == true && gateway.status?.accessCodeVersion != 1 {
                Text("重新開啟共用連線，即可套用新版功能。").font(.callout)
                Button("更新共用連線") { Task { await gateway.restart() } }
                    .disabled(gateway.working || changed)
            }
            ForEach(gateway.status?.roots ?? []) { root in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("\(root.name) · 要求通行碼", isOn: Binding(
                        get: { root.codeRequired == true },
                        set: { required in
                            Task { _ = await gateway.perform("code-policy", workspaceID: root.id, codeRequired: required) }
                        }
                    ))
                    .disabled(gateway.working || changed || gateway.status?.state == "unknown"
                              || (gateway.status?.running == true && gateway.status?.accessCodeVersion != 1))
                    if root.codeRequired == true {
                        let count = gateway.status?.folderAccess?.first { $0.workspaceID == root.id }?.unlockedCount ?? 0
                        HStack {
                            Text(count > 0 ? "\(count) 個暫時讀取授權" : "已鎖定").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("產生通行碼") { Task { _ = await gateway.perform("folder-code", workspaceID: root.id) } }
                            Button("即時鎖定") { Task { _ = await gateway.perform("lock-folder", workspaceID: root.id) } }
                        }.disabled(gateway.working || changed || !gateway.usable || gateway.status?.accessCodeVersion != 1)
                        if let code = gateway.folderCodes[root.id] {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let remaining = max(0, Int(ceil(code.expiration.timeIntervalSince(context.date))))
                                if remaining > 0 {
                                    Text(code.code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                    HStack {
                                        Button("複製解鎖句子") { gateway.copy(code.unlockPrompt) }
                                        Text("\(remaining / 60):\(String(format: "%02d", remaining % 60)) 後過期 · 只用一次")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("通行碼已過期。").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if saved.isEmpty { Text("先選擇並儲存 Folders。").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("通行碼說明") {
                Text("重新產生或即時鎖定會撤銷該 Folder 嘅通行碼及暫時讀取權。關閉要求後，恢復原有 OAuth 存取。未開啟通行碼嘅其他 Folders 仍可讀取。碼會留喺你貼入嘅對話；App 重啟共用連線後要重新解鎖。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
    }
}
