# Shared Tunnel — 實作及遷移

## 已實作

- 新 Main Gate：`https://<instance-hostname>/mcp`。
- 新 Side Gate：`https://<instance-hostname>/side/<gate-id>/mcp`。
- Side Gate 使用 Main registry 嘅內置 Tailscale identity、登入及同一個 Funnel listener；唔會建立第二個 tsnet node。
- Main Gate Local host 可以關閉，Side Gates 繼續透過同一個 transport 運作。
- MCP、OAuth registration / authorize / token / revoke、discovery 同 health 都按 Gate 路徑分流。
- 公開入口只接受固定 localhost port；每次請求核對 Gate ID + runtime instance ID，並傳遞 lifetime header 避免 port 重用競態。
- 每個 Gate 保留自己 AuthStore、pairing、Folder ACL、Passcode policy、desired-running 同 Local service。
- Close / Remove 只退役該 Gate route；共用 Sign Out 才會停止全部共用公開入口。
- 移除一個 MCP Connection 會刪除其全部 access / refresh credentials、未交換 authorization codes 及 temporary Folder access；其他 Gate / clients 不受影響。
- 檔案讀取完成前再核對 OAuth credential，避免已撤銷嘅 in-flight request 繼續交出內容。
- Gate 無 Folder / MCP authorization 仍可啟動；共用 Tunnel 唔會授予任何 Folder 存取權。

## 舊連線及遷移

已有固定 URL 嘅 Main Gate 保留 `/c2c/<main-id>/mcp`，毋須更改 AI app。
舊 Side Gate URL 同 provider 保留，唔會自動轉走已配對 endpoint。
尚未建立固定 endpoint 嘅內置 Side Gate，改用共用 identity；Gate ID / epoch 保留。

已配對 Side Gate 可喺 **Secure Access → … → Use Shared Secure Access…** 明確遷移。
Main Gate 嘅共用內置 Tailscale 必須已登入；遷移唔會偷偷開 browser。

遷移會：

1. 保存 private migration journal。
2. 停止該 Side Gate 舊 service / route，保留 AuthStore。
3. 保存新 URL 及舊 provider / URL history。
4. 重新啟動該 Gate，註冊共用路由。
5. 成功後移除 journal；失敗嘗試復原舊 endpoint，復原未完成則保留 Retry。

新 URL 要喺已連接 AI app 更新；視乎 AI app，可能需要重新 OAuth 一次。
後端 Gate ID 同有效 tokens 保留，唔會借 Main Gate token 授權 Side Gate。
遷移之後新增 Side Gate 唔需要另一輪 Tailscale 登入。

**外置 Tailscale / Cloudflare 舊連線保留。** 今次共用入口實作使用 App 內置 Tailscale。
若 Main Gate 仍綁外置 Tailscale，需另行明確遷移 Main transport；今次唔會自動轉其身份或既有域名。

## Runtime enforcement

Gate 路由、runtime nonce、OAuth Gate ID、client revoke、Folder ACL 同 Passcode 都係 backend enforcement。
`Authorized` 表示 authorization relationship，唔會假稱有 AI-side live session。
UI `sharedTunnel` / migration fields只描述後端 transport mode；唔會用 sidebar 顯示代替存取限制。

## 驗證

- Native Tunnel：Main + 兩個 Side 共用一個 listener；MCP / OAuth / discovery 分流、admin 路由拒絕、nonce mismatch / port 重用拒絕、Close 隔離、並行 race 檢查。
- Node 整合：真實 launcher / Gate daemon / OAuth PKCE / MCP read；只 mock Tailscale account/Funnel，同一帳戶一次登入、0 Folder Main、跨 Gate token 拒絕、client revoke 及 refresh 拒絕、Close / Remove、route restart、舊 Side CLI 遷移及 token 保留。
- Migration：失敗復原原 URL，Main config / Gate ID / epoch / authorization 保留。
- Swift：共用 Side URL parsing、shared account next action、既有 UI / lifecycle tests。

上述測試唔代表已代用戶完成真實 Tailscale browser 授權或外部 AI app 遷移。

## 今次修改檔案

Native：`Native/Tunnel/main.go`、`main_test.go`、新增 `shared.go` / `shared_test.go`。

Backend：`Resources/Tailscale/embedded.mjs`；`Resources/Gateway/registry.mjs`、`side-registry.mjs`、`launcher.mjs`、`side-lifecycle.mjs`、`server.mjs`、`auth.mjs`、`access.mjs`；新增 `side-migration.mjs`。

UI：`Sources/C2CManager/ConnectionDiagnostics.swift`、`SharedGatewayStore.swift`、`SharedGatewayView.swift`、`SecureAccessPresentation.swift`。

Tests：`Tests/Gateway/side-lifecycle.test.mjs`、`side-journey-launcher.test.mjs`、`zero-folder-launcher.test.mjs`；新增 `shared-tunnel.test.mjs`；`Tests/C2CManagerTests/ConnectionDiagnosticsTests.swift`、`SecureAccessPresentationTests.swift`。

Docs：`docs/shared-tunnel-architecture-target.md`、本文件。
