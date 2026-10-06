# Boundas Gate 1.2.0（build 6）

2026-10-06，本機 Apple Silicon 試用版。

## 今次完成

- App 內置 Node.js 24.19.0、已驗證 C2C 0.1.3 build、完整 production dependencies 及 cloudflared 2026.9.1，保留原始授權文件。
- 新安裝共用模式預設內置 Tailscale tsnet 1.104.0，使用 userspace networking、持久裝置身份同私人控制端點；App 提供登入／HTTPS／Funnel 授權連結。
- 舊固定地址保持 external transport，保留 URL、gateway ID、OAuth 同分享清單；唔會自動換成新裝置身份。
- 修正慢啟動時未產生登入連結，重試登入沿用同一個核心程序及身份。
- 產生 `.app`、ZIP、DMG 同 SHA256SUMS，附安裝說明。

## 驗收

| 項目 | 結果 |
| --- | --- |
| Swift App tests | PASS，40 項 |
| Gateway／連線 tests，使用 bundle Node + backend | PASS，40 項 |
| Go 公開路由／身份／並發 tests，race detector | PASS，7 項 |
| 空白 HOME、無 system Node／C2C：CLI、核心、登入連結 | PASS |
| 重試登入保留內置核心及身份 | PASS |
| 安裝 archive 解壓後簽署驗證 | PASS，ad hoc |
| 現有共用 Gateway 改用 bundle runtime，Stop／Start | PASS，URL／gateway ID／多個 roots 不變 |
| 原有 既有 MCP Plugin 列出多個 Folder、讀取 manager folder | PASS，冇重新 OAuth／pairing |

內置核心測試使用暫存設定，測試後移除；冇登入 Tailscale 帳戶或開公開 Funnel。Live upgrade 使用用戶原本 external transport，保留所有授權。

## 修改檔案

### App

- `Sources/C2CManager/RuntimePaths.swift`（新增）
- `Sources/C2CManager/C2CClient.swift`
- `Sources/C2CManager/SharedGatewayStore.swift`
- `Sources/C2CManager/SharedGatewayView.swift`

### Gateway／連線

- `Resources/Gateway/launcher.mjs`
- `Resources/Gateway/server.mjs`
- `Resources/Tailscale/embedded.mjs`（新增）
- `Native/Tunnel/go.mod`、`go.sum`、`main.go`、`main_test.go`（新增）

### 打包／測試／文件

- `scripts/build-app.sh`
- `scripts/bundle-runtime.mjs`、`collect-go-licenses.mjs`、`package-release.sh`（新增）
- `Tests/C2CManagerTests/RuntimePathsTests.swift`（新增）
- `Tests/Tailscale/embedded.test.mjs`（新增）
- `Tests/Release/portable.mjs`（新增，可重跑空白設定 smoke test）
- `README.md`、`ROADMAP.md`
- `INSTALL.md`、`RELEASE_NOTES.md`（新增）

## 下一階段

- 本人登入內置模式後，完成 Funnel → ChatGPT OAuth → MCP、VPN 並用同另一部 Mac 驗收。
- 舊 external 裝置轉入內置裝置嘅明確遷移流程；目前舊用戶仍需要原本 Tailscale App。
- 固定 GitHub repo／Releases，加入 App 更新通知及簽署更新。
- Developer ID 簽署／公證。本試用包只有 ad hoc 簽署，首次啟動可能需要 macOS 私隱與保安確認。

本版未提供自動更新，亦未聲稱已解決所有 VPN 並用情況。普通升級保留設定及有效 OAuth；內置新裝置唔保證沿用舊裝置 URL。
