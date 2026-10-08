import Foundation

struct ConnectionGuidance {
    enum Action { case chooseFolder, check, repair, setup }
    let title: String
    let message: String
    let button: String
    let action: Action
    let needsAttention: Bool

    static func make(workspace: WorkspaceRecord, status: WorkspaceStatus?, diagnostics: ConnectionDiagnostics?,
                     checking: Bool, folderExists: Bool) -> Self {
        if !folderExists {
            return .init(title: "搵唔到呢個 Folder", message: "Folder 可能搬咗位置，或者外置硬碟未接駁。接返硬碟後再檢查；如果搬咗位置，請加入新位置嘅 Folder。",
                         button: "加入正確嘅 Folder", action: .chooseFolder, needsAttention: true)
        }
        if checking {
            return .init(title: "正在檢查連線…", message: "App 正在確認 ChatGPT 可唔可以連到呢個 Folder，請稍等。",
                         button: "檢查中…", action: .check, needsAttention: false)
        }
        if status?.running == false {
            return .init(title: "呢個 Folder 嘅連線未開啟", message: "撳下面個掣，App 會啟動連線，再一步步帶你喺 ChatGPT 完成設定。",
                         button: "連接 ChatGPT…", action: .repair, needsAttention: false)
        }
        guard status?.running == true, let diagnostics else {
            return .init(title: "暫時未能確認連線", message: "先讓 App 再檢查一次。如果仍然有問題，可以複製求助資料俾人幫你睇。",
                         button: "重新檢查", action: .check, needsAttention: true)
        }
        if !diagnostics.isUsable {
            let message: String
            if !diagnostics.bridge.passed {
                message = "Mac 上嘅連線未能正常回應。撳下面個掣，App 會重新啟動連線，再帶你完成設定。"
            } else if !diagnostics.address.passed || diagnostics.localMCP.state == .failed || diagnostics.publicMCP.state == .failed {
                message = "連線設定未能對上。撳下面個掣，App 會重新建立連線，並準備正確嘅地址俾 ChatGPT 使用。"
            } else {
                message = "Mac 上嘅連線正常，但 ChatGPT 暫時未能透過網絡連入。撳下面個掣，App 會重新建立連線，再帶你完成設定。"
            }
            return .init(title: "ChatGPT 暫時連唔到呢個 Folder", message: message,
                         button: "幫我修復連線…", action: .repair, needsAttention: true)
        }
        switch workspace.connectorState(currentURL: status?.mcpURL) {
        case .needsUpdate:
            return .init(title: "要更新 ChatGPT 嘅連線地址", message: "Mac 上嘅連線已準備好，但地址同你上次記錄嘅唔同。跟住引導複製新地址，再喺 ChatGPT 更新設定。",
                         button: "帶我更新 ChatGPT…", action: .setup, needsAttention: true)
        case .unconfirmed:
            return .init(title: "Mac 已準備好，下一步設定 ChatGPT", message: "跟住引導複製地址、完成配對，再試一次讀取檔案。已經設定過亦可以用引導確認。",
                         button: "帶我設定 ChatGPT…", action: .setup, needsAttention: false)
        case .matches:
            return .init(title: "Gate Open", message: "地址同你確認過嘅 ChatGPT 設定一致。如果 ChatGPT 仍然連唔到，可以用引導再設定同測試。",
                         button: "ChatGPT 仍然連唔到？", action: .setup, needsAttention: false)
        }
    }
}

struct ConnectionSetupProgress {
    private(set) var address: String?
    private(set) var addressCopied = false
    private(set) var settingsConfirmed = false
    private(set) var testPromptCopied = false

    mutating func observe(_ url: String?) {
        let normalized = EndpointAddress.mcpURL(url)
        guard normalized != address else { return }
        address = normalized
        addressCopied = false
        settingsConfirmed = false
        testPromptCopied = false
    }

    mutating func markAddressCopied(_ url: String?) {
        guard let current = EndpointAddress.mcpURL(url), current == address else { return }
        addressCopied = true
    }

    mutating func confirmSettings(_ url: String?) -> Bool {
        guard addressCopied, let current = EndpointAddress.mcpURL(url), current == address else { return false }
        settingsConfirmed = true
        return true
    }

    mutating func markTestPromptCopied() { if settingsConfirmed { testPromptCopied = true } }

    var canConfirmTest: Bool { settingsConfirmed && testPromptCopied }
}

enum ConnectionSupportReport {
    static func make(workspace: WorkspaceRecord, status: WorkspaceStatus?, diagnostics: ConnectionDiagnostics?) -> String {
        var lines = ["Boundas Gate 連線求助資料", "時間：\(Date().ISO8601Format())",
                     "Folder：\(workspace.name)", "Folder ID：\(workspace.c2cID)",
                     "本機程序：\(status?.running.map { $0 ? "運行中" : "已停止" } ?? "未確認")",
                     "Port：\(status?.port.map(String.init) ?? "未確認")",
                     "地址：\(EndpointAddress.mcpURL(status?.mcpURL) ?? "未取得")"]
        if let diagnostics {
            for (name, check) in [("本機 Bridge", diagnostics.bridge), ("本機 MCP", diagnostics.localMCP),
                                  ("公開端點", diagnostics.publicEndpoint), ("公開 MCP", diagnostics.publicMCP),
                                  ("URL 一致性", diagnostics.address)] {
                let state = check.state == .passed ? "通過" : check.state == .failed ? "失敗" : "未檢查"
                lines.append("\(name)：\(state) · \(check.detail)")
            }
        }
        // Keep CLI output, local paths and pairing credentials out of the shareable report.
        return lines.joined(separator: "\n")
    }
}
