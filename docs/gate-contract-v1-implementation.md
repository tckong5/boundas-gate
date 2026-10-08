> 歷史實作報告。2026-10-08 已用正式 Side Gate unlock 取代本文原有 fail-closed 暫行方案；最新實作見 [security-robustness-review.md](security-robustness-review.md)。

# Gate contract v1 — 實作及驗證

日期：2026-10-07

Contract：[Product Model / Architecture Invariants v1](product-model-architecture-invariants-v1.md)。Contract semantics 保持不變。

## Review 發現及修正

| 原有衝突 | 修正 |
| --- | --- |
| `sideGateAdded` 只篩選 sidebar | Store 所有 Side lifecycle、批量操作、refresh、diagnostics 及 counts 依 membership 篩選；Node helper 再檢查 persisted registry |
| Remove 會撤銷 Main 分享並刪 Folder | 分開 `Remove Side Gate` 與 `Remove Folder`；Side decommission 完成後才取消 membership |
| Folder 數量係 start / pair / reconnect prerequisite | Main Gate identity 可獨立初始化；server、launcher、pairing、reconnect policy 及 UI 都接受空清單 |
| Gate Open 依賴授權及 Folder 數量 | runtime `isOpen` 只依 Local + Tunnel；`isReady` 保留為 setup journey |
| UI 混用 Workspace / Repository / AI Connection | 一般 UI 使用 Folder / Gate / Tunnel / MCP Connection；internal API names 保留 |
| Main Passcode 可以被 Side 繞過 | 按用戶確認，Protected Folder 經 Side 暫時拒絕存取；完整 Side unlock 另做 |

## Runtime enforcement

### Side Gate membership

- Main Gate Add Folder 預設 `sideGateAdded = false`。
- Side Gates Add by Path / Add Folder 可以加入現有或新 Folder；不會複製 Folder record。
- Main-only Folder 不會被 Side start / stop / reconnect / refresh / diagnostics / counts 使用。
- `side-lifecycle.mjs` 每個操作從磁碟重新檢查 membership，拒絕 Main-only、移除中及失敗待重試嘅 Gate。
- 新 Side daemon 每次 bearer request 重新檢查 Folder membership 及 Passcode policy；membership 被移除時停止服務。
- 使用現有 Cloudflare / Tailscale providers；沒有新增 ngrok 或 TunnelProvider framework。

### Remove Side Gate

1. 先持久化 `removing`，保留 row。
2. 確認 service identity、Folder path 及本機 admin credential；未知服務唔會 blind kill。
3. 停止 Side-owned Tunnel，撤銷 Side MCP tokens／pairing，停止 bridge。
4. 清理本 Gate journalled routes、Side auth file、runtime admin credential、daemon marker。
5. 清除 active / configured MCP URL；`lastKnownMCPURL` 只保留作 history。
6. 成功儲存後 `sideGateAdded = false`；Folder identity/path/name/provider preference 保留。
7. 失敗保留 `failed` 及 Retry；中途 App 重開會恢復成 Retry 狀態。

Main Gate config、auth、分享狀態及 Passcode policy 不會被 Side remove 修改。

`Remove Folder` 只刪 App record，不刪 filesystem Folder，亦唔 stop Main Gate。有 Side Gate 嘅 Folder 要先完成 Remove Side Gate。

### Authorization isolation

- Main Gate 用獨立 Gate ID／AuthStore；每次 file operation 仍驗證 current shared registry。
- Side Gates 使用自己嘅 workspace-bound AuthStore／runtime；跨 Gate token 會被拒絕。
- Side remove 會刪 Side auth state；重新加入同一 Folder，不會重新啟用舊 access／refresh token 或 registration。
- Authorized 只代表持續有效嘅授權，不代表 active request 或 live AI session。

### Zero Folder Main Gate

- Gate ID、Local service、Tunnel、pairing／OAuth 均可以先於 Folder 存在。
- `list_workspaces → []` 係正常結果。
- 移除最後一個 Folder 即時 revoke 資源存取，但 Local/Tunnel 仍可以 Open。
- 空 registry 同樣允許 reconnect、crash recovery、stop/start；原有 Gate ID／OAuth／固定 URL 保留。
- 零 MCP authorizations 不會令 runtime Gate Closed。

### Passcode

Policy 目前仍保存在 Gateway registry root metadata，按 Folder identity 讀取，唔係新建一套 policy store。

Main Gate unlock／temporary access 行為維持原有 semantics。Side bearer guard 會讀取同一 Folder 嘅 policy，包括 Main sharing 已取消但 policy 仍存在嘅 Folder。

**目前限制：** Protected Folder 經 Side Gate 一律拒絕，未有 Side unlock API。Main temporary access key 唔會跨 Gate grant 授權。此處係用戶明確接受嘅保守處理；唔宣稱已完成跨 Gate unlock。

## UI / metadata 與 runtime 嘅區分

| 項目 | 層次 |
| --- | --- |
| Side membership、decommission、跨 Gate token 拒絕 | 實際 Store / Node / MCP runtime enforce |
| Folder dynamic ACL、path / symlink / readonly restrictions | 原有 server checks 保留，integration tests 覆蓋 |
| Main zero Folder startup / pair / recover | 真正 launcher + daemon + OAuth runtime |
| Gate Open vs setup Ready | UI mapping；依實際 Local/Tunnel diagnostics，冇新增網絡 state machine |
| MCP client Authorized / Invalid / Not authorized | 持久化 authorization evidence，唔係 live client health |
| `lastKnownMCPURL`、provider / domain reservation | history / configuration metadata，唔係 active endpoint |
| Passcode Side support | 真正 fail-closed；完整 temporary unlock 尚未實作 |

## Migration

- 新增 Folder／普通 Main restart 不需要重新 Add Plugin 或 OAuth。
- 舊 record 缺少 membership 時，只以曾記錄嘅 Side endpoint 作一次 migration；provider preference 本身唔會建立 Side Gate。
- 舊 Side daemon 缺少新 membership / policy guard，第一次 refresh 會安全停用佢；重新 Open Side Gate 即安裝新 guard，保留原有 OAuth。
- 若 runtime identity 或 route ownership 無法確認，操作會失敗並保留 Retry／diagnostics，不會隱藏 row 或動其他 Gate。
- Remove Side Gate 後 re-add 屬新授權流程，需要重新配對，符合 decommission semantics。

## 驗證

Debug build：✅ 成功。

Swift：55 tests PASS；Gateway／Tunnel Node：52 tests PASS。最後 Side lifecycle 修正亦再跑相關 tests。

| 驗收 | Result | 覆蓋 |
| --- | --- | --- |
| Main Add Folder 不自動加入 Side | PASS | Swift Store + Node membership checks |
| Main-only 不受 Side batch start / stop / reconnect / refresh | PASS | Swift lifecycle tests |
| 現有／新 Folder 加入 Side | PASS | Swift lifecycle tests |
| Remove Side 後 Folder 仍存在 | PASS | Store persistence + 真 Side daemon |
| Main Gate 分享／授權完全不變 | PASS | 真 OAuth/file read + Main config/auth bytes 比對 |
| Remove 失敗保留 row，可 Retry | PASS | Store failed/restart/retry + route cleanup failure |
| Re-add 不復活舊 authorization | PASS | 真 Side OAuth token 被拒絕，再配對後正常 |
| 同一 Folder Main / Side coexist | PASS | 真 MCP requests，移除 Side 後 Main 仍可讀 |
| Main token → Side / Side A token → Side B | PASS | 真 HTTP/MCP 401；反方向同樣拒絕 |
| 0 Folder startup / pair / reconnect / recovery | PASS | 真 launcher/daemon/control + local transport IPC fixture |
| 最後 Folder 移除，Gate 仍 Open | PASS | 真 Main service/Tunnel fixture，list 空、舊 root access 拒絕 |
| Protected Folder Side 不可繞過 | PASS | 真 bearer guard，包括 Main sharing disabled |
| 舊 Side daemon migration 保留 OAuth | PASS | 舊 C2C daemon → 安全停止 → 新 daemon 接受原 token |

測試用了真正本機 MCP/OAuth/daemon；transport 部分使用隔離 fixtures，冇把 fixtures 當成外網 health。未做完整 manual UX 或真實外網安裝驗收。

## 今次修改檔案

### App

- `Sources/C2CManager/WorkspaceRecord.swift`
- `Sources/C2CManager/WorkspaceStore.swift`
- `Sources/C2CManager/C2CClient.swift`
- `Sources/C2CManager/SharedGatewayStore.swift`
- `Sources/C2CManager/GatewayReconnectPolicy.swift`
- `Sources/C2CManager/GateConnectionJourney.swift`
- `Sources/C2CManager/SharedGatewayView.swift`
- `Sources/C2CManager/C2CManagerApp.swift`
- `Sources/C2CManager/ConnectionGuidance.swift`

### Runtime

- `Resources/Gateway/registry.mjs`
- `Resources/Gateway/launcher.mjs`
- `Resources/Gateway/server.mjs`
- `Resources/Gateway/side-lifecycle.mjs`（新增）
- `Resources/Gateway/oauth-presentation.mjs`
- `Resources/Tailscale/provider.mjs`
- `Resources/Tailscale/embedded.mjs`

### Tests / docs

- `Tests/C2CManagerTests/SideGateLifecycleTests.swift`（新增）
- `Tests/C2CManagerTests/GateConnectionJourneyTests.swift`
- `Tests/C2CManagerTests/GatewayReconnectPolicyTests.swift`
- `Tests/C2CManagerTests/SharedGatewayConnectionTests.swift`
- `Tests/Gateway/gateway.test.mjs`
- `Tests/Gateway/side-lifecycle.test.mjs`（新增）
- `Tests/Gateway/zero-folder-launcher.test.mjs`（新增）
- `docs/gate-contract-v1-implementation.md`（本文件）

## 可開啟 build

- `dist/Boundas Gate Debug.app`
- `dist/Boundas Gate New User Test.app`

更新兩個既有 Debug / isolated test bundles，冇重置 Folder／OAuth 資料。一般 release bundle 仍維持原版。今次冇 commit，冇做 ngrok。
