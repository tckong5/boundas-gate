# Boundas Gate — Product Model / Architecture Invariants v1

下一版已確認嘅 Tunnel ownership 目標見
[Shared Tunnel 架構目標](shared-tunnel-architecture-target.md)。該文件記錄共享登入／
transport 同獨立 Gate routing 嘅新方向；現有 runtime 尚未完成該重構。

## Core invariants

> A Gate can exist with zero Folders.
>
> A Gate can be Open with zero MCP Connections.
>
> A Folder may belong to Main Gate, have a Side Gate, or both.
>
> Removing a Side Gate never removes the Folder or changes Main Gate state.

呢份係 v1 product contract。之後任何 implementation 同以上四句衝突，都應該當 regression，而唔係再重新討論 UX。

---

## 1. Core model

Gate 係一個獨立管理嘅 MCP endpoint，擁有自己嘅 lifecycle 同 authorization boundary。

Gate 唔等於 Folder，亦唔等於 Tunnel。

```text
Gate
├── Tunnel
├── 0..n MCP Connections
└── 0..n Folder Access
```

Main Gate：

```text
1 Gate → 0..n Folders
```

Side Gate：

```text
1 Gate → exactly 1 Folder
```

同一個 Folder 可以同時：

```text
Main Gate ✓
Side Gate ✓
```

兩者 connection state 必須互相獨立。

---

## 2. Gate existence ≠ Folder existence

Gate 必須可以喺 0 Folder 情況正常存在及運作。

合法：

```text
Gate Open
0 MCP Connections
0 Folders shared
```

亦合法：

```text
Gate Open
2 MCP Connections
0 Folders shared
```

AI call：

```text
list_workspaces → []
```

係正常結果，唔係 error。

因此 Folder 唔可以係：

- Gate startup prerequisite
- Tunnel prerequisite
- MCP authorization prerequisite
- reconnect prerequisite

移除最後一個 Folder亦唔可以自動拆 Gate。

---

## 3. Runtime Gate status

唔好用一個 Ready boolean代表晒所有事情。

Gate runtime health主要係：

- Gate Open
- Gate Closed
- Opening Gate…
- Reopening Gate…
- Gate Needs Attention

其中：

**Gate Open = Gate endpoint正常 + required transport/tunnel正常。**

MCP Connections同Folders係獨立資訊。

例如：

```text
● Gate Open
2 MCP Connections · 0 Folders shared
```

冇 MCP Connection唔代表 Gate Closed。

冇 Folder亦唔代表 Gate Closed。

Ready 可以繼續用喺 first-run/setup journey，但唔應該成為核心 runtime state。

---

## 4. Setup journey

First-run可以保持：

```text
Local
  ↓
Tunnel
  ↓
MCP Connection
  ↓
Ready
```

呢個係 setup journey，唔係 Gate state machine。

例如 Gate已經 Open，但冇 MCP authorization，可以顯示：

```text
Gate Open
0 MCP Connections
[ Set Up MCP Connection ]
```

---

## 5. MCP Connection

User-facing terminology：

**MCP Connection**

代表一個 external MCP client同某個 Gate之間嘅 authorization relationship。

例如：

```text
ChatGPT       Authorized
Claude        Authorized
Other Client  Invalid
```

Authorized 唔等於「而家有 live session」。

除非真係有 runtime session evidence，唔好用：

- Connected
- Disconnected

每個 MCP authorization必須只屬於 **一個 Gate**。

核心 security invariant：

```text
Main Gate authorization
≠
Side Gate A authorization
≠
Side Gate B authorization
```

唔可以跨 Gate reuse authorization。

---

## 6. Folder

User-facing一律叫：

**Folder**

唔好再喺一般 UI混用：

- Workspace
- Repository

除非功能真係 Git-specific，先用 Repository。

Internal code可以繼續用 `WorkspaceRecord`，唔需要為 terminology立即重構 model names。

---

## 7. Side Gate membership

Folder本身同 Side Gate membership係兩回事。

```text
Folder exists
        ≠
Side Gate exists
```

`sideGateAdded` 唔可以只控制 sidebar display。

佢必須真正控制：

- Side Gate startup
- refresh
- reconnect
- diagnostics
- counts
- lifecycle operations

Main-only Folder唔應該被 Side Gate batch startup／reconnect碰到。

---

## 8. Remove Side Gate

User action叫：

**Remove Side Gate**

而唔係 Remove Workspace。

呢個操作代表 decommission獨立 Gate，唔係刪 Folder。

流程：

```text
Active
  ↓
Removing…
  ↓
stop Side Gate
revoke Side Gate authorization
retire active tunnel/route
clear runtime credentials
  ↓
sideGateAdded = false
```

完成後必須保留：

- Folder identity/path/name
- Main Gate membership
- Main Gate sharing state
- Passcode policy
- preferred Tunnel provider

必須清除／失效：

- Side Gate MCP authorizations
- pairing secrets
- temporary credentials
- runtime diagnostics
- active endpoint binding
- configured active MCP URL

可以保留：

- lastKnownURL
- provider/domain reservation identity

但只可以係 history/config metadata，唔可以再當 active endpoint。

如果 remove過程失敗：

```text
Removing Failed
[ Retry ]
```

唔可以先隱藏 Side Gate，再留一堆 orphan runtime state。

---

## 9. Passcode

正式採用以下 policy（Security / Robustness Review，2026-10-08）：

**Passcode Protection = Folder-level policy。**

即：

```text
Folder A
Passcode Protection ON
```

只要任何 Gate expose Folder A，都需要 obey同一個 Passcode policy。

包括：

```text
Main Gate → Folder A
Side Gate → Folder A
```

原因係目前 UI mental model係：

> 呢個 Folder有 Extra Protection。

如果 Main Gate要Passcode，但Side Gate可以繞過，就會違反 user expectation。

如果日後真係有需要做到不同 Gate不同policy，再升級成 Gate-Folder policy；v1唔建議增加呢個 complexity。

Main Gate 同 Side Gate 共用同一套 `FolderAccess` generate / unlock / expiry / revoke 機制；Passcode ON 唔再永久封鎖 Side Gate。Side-only Folder 亦有 Folder policy，唔需要先經 Main Gate 分享。

Temporary unlock **唔係 Folder global unlock**。每個 access key 必須同時符合：

- Gate ID（每個 Gate 獨立 AuthStore、code / key storage）
- OAuth credential hash（refresh / 換 credential 唔會自動繼承 key）
- Folder ID、membership epoch、policy epoch
- Conversation metadata；AI app 冇提供 metadata 時，用明確 `session_id`，仍須持有相符 OAuth credential + access key
- 最長 30 分鐘，且唔超過 OAuth access token expiry

Passcode 5 分鐘到期、一次性。Generate New Code / Invalidate / Revoke 只撤銷該 Gate 嘅 Folder codes / grants；policy 開關會改共享 policy epoch，令 Main / Side 舊 grants 一併失效。Gate restart 清空臨時 code / grant，持久 OAuth authorization 保留。

Protected Folder 每次 tool operation（包含 Git / execution reads）前後均重新核對 ACL / policy / grant，唔可以用 Main Gate key 解鎖 Side Gate。

詳見 [security-robustness-review.md](security-robustness-review.md)。

---

## 10. Tunnel

Tunnel只負責：

**令外部可以 reach 到 Gate。**

唔負責：

- OAuth
- MCP authorization
- Folder ACL
- Passcode
- Gate identity

呢啲全部屬於 Boundas Gate Core。

Architecture：

```text
Gate Core
   ↓
Tunnel Layer
   ↓
TunnelProvider
   ├── Tailscale
   ├── ngrok
   └── future providers
```

每個 Gate v1只綁一個 active TunnelProvider。

暫時唔做 transparent hot-switch。

換 provider視為 endpoint migration。

---

## 11. TunnelProvider abstraction

而家先 freeze boundary，唔需要未有 ngrok就抽完整framework。

ngrok spike時正式抽 common interface。

最低需要支援：

- prepare
- start
- stop
- status
- endpoint

Provider可以回報 capabilities，例如：

- stableEndpoint
- customDomain
- interactiveLogin
- perGateEndpoint
- sharedIngress

Reconnect policy、desired-running、retry/backoff應由 Gate coordinator控制，唔應該塞入每個provider自己管理。

---

## 12. Product terminology

最終 user-facing vocabulary：

- Folder
- Gate
- Main Gate
- Side Gate
- Tunnel
- MCP Connection
- Passcode Protection

其中：

**Gate**

= independently managed MCP endpoint + authorization boundary + lifecycle

**Tunnel**

= external reachability mechanism

**MCP Connection**

= external MCP client authorization to one Gate

**Folder**

= resource exposed through a Gate

---

## 13. Implementation priority

我會正式排成：

1. **Freeze以上 semantics**

2. **修 Side Gate lifecycle**

   令 `sideGateAdded` 真正貫穿 start / stop / reconnect / refresh / remove。

3. **同步補 Side Gate tests**

   唔好等功能做完先補。

4. **完成 0 Folder Gate**

   由 backend/server/launcher/reconnect到UI全部解除Folder prerequisite。

5. **Cleanup user-facing terminology**

   Folder / Gate / Tunnel / MCP Connection統一。

6. **ngrok spike**

   先驗證 stable endpoint、OAuth callback、streaming、restart、multi-Gate。

7. **spike期間抽 minimal TunnelProvider**

8. **最後做 provider selection / migration UI**
