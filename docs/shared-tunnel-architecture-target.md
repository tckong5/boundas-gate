# Boundas Gate — Shared Tunnel 架構目標

狀態：App 內置 Tailscale 共用入口已實作；詳見 [實作及遷移說明](shared-tunnel-implementation.md)。

呢份係 [Product Model / Architecture Invariants v1](product-model-architecture-invariants-v1.md)
嘅 Tunnel ownership 補充。Gate lifecycle、Folder membership、Passcode policy
及獨立 MCP authorization boundary 保持原有 contract。

## 1. 產品目標

- 一個 Boundas Gate instance 共用一個 Tailscale account/device identity、一次
  初始授權同一條 active Tunnel。新增 Side Gate 唔再建立另一個 Tailscale
  裝置或要求另一輪 Tailscale 登入。
- Main Gate 同各 Side Gate 使用同一個 HTTPS origin，各自有穩定 URL 路徑。
- 每個 Gate 繼續係獨立 MCP endpoint、authorization boundary 同 lifecycle。
- Tailscale 授權與 MCP 授權係兩件事：共用 Tunnel 唔會授權 AI 存取任何 Gate。
- 未授權嘅 Side Gate 預設拒絕 AI 存取。分享 Folder、開 Local host 或開 route
  都唔等於授予 MCP 存取權。

## 2. URL 及 routing

概念路徑：

```text
https://<instance-hostname>/mcp
https://<instance-hostname>/side/<gate-id>/mcp
```

例子唔代表可以任意取得 `boundas-gate.ts.net`；實際 origin 由現有 Tailscale
帳戶／裝置域名提供。Gate ID 穩定且唔依賴 Folder display name，Rename 唔改 URL。

共享 ingress 只可以按 server-side route registry，將固定 Gate 路徑送到已驗證、
由該 Gate 擁有嘅 loopback service。唔可以由 client 指定任意 localhost port、
absolute Folder path 或 target URL。

Routing 必須一併處理各 Gate 嘅 MCP、OAuth discovery／registration／authorize／
token／callback 同 health，唔可以只 multiplex `/mcp`。每個 Gate 嘅 issuer、
resource metadata、OAuth scopes／audience 同授權儲存必須一致；實際 discovery
路徑先按現有 implementation 同相關標準核對，唔假設所有 clients 使用同一方式。

## 3. Ownership 同 lifecycle

```text
Boundas Gate instance
├── Shared Tailscale identity / Tunnel runtime
└── Gate route registry
    ├── Main Gate → owned Local service → independent AuthStore / Folder access
    ├── Side Gate A → owned Local service → independent AuthStore / Folder access
    └── Side Gate B → owned Local service → independent AuthStore / Folder access
```

- Shared transport coordinator 管理 account、Tunnel runtime、retry/backoff 同
  active ingress；Gate coordinator 管理自己嘅 Local service、route 同 desired-running。
- Open Gate 仍然只開本機層。首次 Secure Access 授權仍由 user 明確啟動。
- 已有共享 transport 授權時，新 Gate 只需建立自己嘅 route，唔再登入 Tailscale。
- Close Main Gate／Side Gate 只停止該 Gate 嘅 service／route，唔登出共用帳戶，
  唔停止其他 Gate，唔撤銷持久 MCP authorization。
- Remove Side Gate 必須完成該 Gate 嘅 decommission、revoke 同 route retirement
  後先隱藏 membership；失敗仍可 Retry。Folder 同 Main Gate 狀態保留。
- Shared Sign Out 屬於 instance-wide action，必須明確提示會影響所有使用共享
  Tunnel 嘅 Gates，並由 user 確認。
- Shared Tunnel 正常唔等於每個 Gate 都 Open；每個 Gate 必須有自己正常嘅
  Local service 同 active route。0 MCP Connections／0 shared Folders 唔阻止 Open。
- 最後一條 route 關閉後，可停止不再需要嘅 listener，但保留 transport identity
  同登入設定；重新開 Gate 唔應該因此重新登入。

## 4. Authorization 及 revoke 必須由 runtime enforce

```text
Main Gate authorization ≠ Side Gate A authorization ≠ Side Gate B authorization
```

- Ingress 揀定 Gate 後，該 Gate 每次 request 都驗證自己嘅 authorization、
  Gate identity、scopes／audience，再驗證 current Folder ACL 同 Passcode policy。
- Main token 唔可以用於任何 Side Gate；Side A token 唔可以用於 Side B。
- 相同 client display name 唔代表同一條 authorization，唔可以按名字跨 Gate revoke。
- 停用／Remove MCP Connection 必須喺該 Gate 後端撤銷 access／refresh credentials、
  該授權相關 pending exchanges 同 temporary grants；下一次 request 同 refresh
  必須被拒絕，唔可以只隱藏 UI row。其他 Gate／client 授權保持有效。
- Authorized 只表示 authorization state，唔假裝有 live session。
- 共用 Tunnel 唔放寬 path traversal、symlink、read-only 或 Folder Passcode 限制。

## 5. Existing clients / migration

- Inspect 現有 Main／Side Gate identities、origins、URL bindings、AuthStore、
  OAuth metadata 同 active helpers，先決定可兼容部分。
- 優先保留現有 Main origin，同各 Gate ID／authorization identity；唔因 transport
  共用就清除授權、重建 Gate 或改 Folder policy。
- 舊 Side Gate 各自嘅 hostname 唔會因新 ingress 路徑存在就自動變 alias。
  維持舊 URL 需要保留相應舊入口，或經 provider 實際支援嘅方式映射到同一 Gate。
  唔假設 HTTP redirect 可以完成所有 MCP／OAuth clients 嘅遷移。
- Client 改到新 URL 如需重新授權，必須清楚提示一次性 endpoint migration；
  唔可以靜默將舊 Side URL 指向 Main Gate，或將跨 Gate tokens 視為兼容。
- 每個 Gate 遷移成功後，先 retire 其舊 route／helper。失敗保留可重試狀態，
  唔先刪有效舊入口。之後新增 Folder／Side Gate 唔再要求 Tailscale 登入。

## 6. 實作次序及驗收

1. Review 最新 tree，列出 per-Gate transport ownership 同本目標嘅差異。
2. 建立最小 shared transport coordinator／固定 ingress route registry，沿用現有
   Tailscale provider；今次唔加入 ngrok，唔抽完整通用 provider framework。
3. 先用 isolated tests 驗證跨 Gate routing、OAuth discovery 同 token isolation。
4. 接入 Main／Side lifecycle，驗證 Close／Remove／reconnect 只影響目標 Gate。
5. 實作 backend connection revoke，驗證 access、refresh 同 temporary access 真正失效。
6. 實作 migration，再將 Secure Access UI 同 shared status 接到新 source of truth。
7. Build Debug、run relevant tests，最後實機驗證同一 Tailscale 授權下連接至少兩個
   Gates、restart、新增 Side Gate、停用單一 AI connection。

必要 cases：首次登入一次；新增 Side Gate 零額外 Tailscale login；0 Folder Main
可 Open；Main／Side A／Side B token 互相拒絕；revoke 即時拒絕後續 reads 同
refresh；Close／Remove 單一 Gate 唔影響其他；restart 保留身份／授權／route
配置；migration 失敗唔產生 orphan 或靜默跨 Gate mapping。
