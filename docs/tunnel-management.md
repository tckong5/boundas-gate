# Tunnel 管理入口

## 今次修改

- Main Gate 嘅 Tunnel stage 同右上角 `…` 均有 `Manage Tunnel…` 入口。
- 管理頁提供登入／連線、登出、重新檢查、開啟 Gate，以及離線時複製已儲存 Server URL。
- 登入會開啟經驗證嘅 Tailscale 授權網址。未登入完成唔會假設 Tunnel 正常。
- Repair 未成功時直接開管理頁，保留 DNS／VPN 提示，避免只有「知道了」嘅死路。
- 內置模式毋須另外安裝 Tailscale；既有外置模式保持原有裝置／地址，冇自動搬遷。

## 登出行為

先停止 Main Gate 同佢擁有嘅 route，再登出 Tunnel。保留 Gate ID、Folders、Main Gate 分享／Passcode policy、MCP 授權、固定 URL。`desiredRunning = false` 防止背景自動重登入。

內置模式只操作該 Gate 嘅 private tsnet agent。舊 helper 未支援登出時，先核對 private endpoint、Gate ID、PID、process owner、executable name 同完整 Gate arguments，先可以停止並換成新版 helper；未知 process 不會被操作。

外置模式沿用 Mac LocalAPI，而非建立新 Tailscale profile。登出前 UI 及 backend 均要求確認：同一外置裝置嘅 Side Gates／其他服務亦會暫停。內置模式唔會顯示呢個外置提示。

普通 Tunnel 登入／登出唔會撤銷 MCP 授權。若登入另一個帳戶令 hostname 改變，沿用既有 URL mismatch 拒絕規則，唔會偷偷改 Server URL。

## 修改檔案

- `Sources/C2CManager/TunnelManagementView.swift`（新增）
- `Sources/C2CManager/SharedGatewayView.swift`
- `Sources/C2CManager/SharedGatewayStore.swift`
- `Resources/Gateway/launcher.mjs`
- `Resources/Tailscale/embedded.mjs`
- `Resources/Tailscale/provider.mjs`
- `Native/Tunnel/main.go`
- `Native/Tunnel/main_test.go`
- `Tests/Tailscale/embedded.test.mjs`
- `Tests/Tailscale/provider.test.mjs`
- `Tests/Gateway/zero-folder-launcher.test.mjs`
- `scripts/build-new-user-app.sh`
- 本文件

## 驗證

- Debug build：成功。
- Swift 相關測試：19 個通過。
- Node Tunnel／launcher 測試：21 個通過。
- Go helper tests：通過。
- 使用隔離本機 fixture 實際測試 logout → login → start：同一 MCP token 可繼續呼叫 `list_workspaces`；Gate ID／固定 URL／授權檔案保留。
- Logout 後 `recover` 被拒絕，而且冇偷偷呼叫 login。
- 外置登出未確認時唔會執行；外置登入唔會建立新 profile。
- 授權 link 拒絕第三方網址、HTTP、帶 username/password URL。

冇操作真實帳戶嘅登入／登出，冇重置用戶資料。
