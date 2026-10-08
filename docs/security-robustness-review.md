# Boundas Gate — Security / Robustness Review

日期：2026-10-08。以本次最新 working tree 為基礎；保留之前未 commit 嘅 lifecycle、Tunnel 管理及 UI 修改。冇 reset、clean、commit、push；冇加入 ngrok 或重構 TunnelProvider。

## 結果

| Priority / Issue | 修正及驗證 |
| --- | --- |
| P0 Git option injection | MCP path 經 Workspace resolve；外部 C2C Git backend 以 `--` 分隔 path；repo-owned wrapper 要求 separator + 固定讀取 command/options allowlist。真實 option-looking filenames 經 MCP / backend / wrapper / Git 測試。 |
| P0 Public OAuth abuse | 保留原有 pairing / PKCE；新增 socket-address + Gate global rate limits、128 registrations cap、abandoned cleanup、256 pending authorization admission cap，同 request size/type limits。 |
| P1 Configure lock | Atomic owner metadata、PID / createdAt / random token；活 owner 唔會因時間長被搶 lock；dead owner / 缺失或損壞 metadata 可恢復；只 owner token 相符先 cleanup。 |
| P1 Runtime / PID reuse | Runtime、health、private info、daemon arguments 同一 nonce；唔再靠 PID alive 判定 running。只清理可證明 stale 嘅記錄，未知 ownership 保留、拒絕操作；唔會 signal stale PID。 |
| P2 Folder Passcode policy | Main / Side 共用 Folder policy 同 FolderAccess；Side 有正式 generate / unlock / revoke API 同現有 popover。Temporary grants 分 Gate、credential、Folder、conversation、expiry。 |
| P3 Resource lookup | App bundle 缺 resource 清楚 fail，唔借 developer tree；只有非 bundled Debug 容許 source fallback。 |
| P3 Diagnostics | CLI 保留 sanitized stack / stderr；App failure log 記錄 stderr + exit status，唔記錄 stdout；私有目錄 / 檔案 permissions。 |
| P3 Registry reads | `active()` 每次 operation 一個 allowlist snapshot；launcher status reuse `active()`。 |
| P3 Duplicate / assets | 刪除 excluded、無引用嘅 `ConnectionStatusView 2.swift`，移除 exclude。保留有 packaging / design 用途或用途未能確定嘅圖。 |

## Git end-to-end trace

1. MCP `git_diff` schema 只提供 mode / path / pagination，唔接受 raw Git flags。Handler 每次核對 Gate、Folder ACL、Passcode；`Workspace.resolve(path).rel` 核對 boundary、traversal、symlink / secrets。
2. 已安裝及 bundled C2C `workspace/git` backend inventory 用 `git diff --name-status -z --find-renames=1% [--cached|HEAD] -- .`；patch batch 用 `git diff --no-color --find-renames=1% [--cached|HEAD] -- :(literal)<path>`。
3. `readGit` PATH 指向 repo-owned `Resources/Gateway/git`；清除 inherited `GIT_*`，停用 system/global config、fsmonitor、hooks，custom filters fail closed。
4. Wrapper 只容許固定 diff / status / rev-parse 讀取形狀。Diff 必须有 `--` 同至少一個 path；separator 前只接受既定 options，拒絕 `--output`、`--config`、`-c`、`--no-index`。Separator 後嘅 `--output=...` 只係 filename。
5. 實際執行 `/usr/bin/git`，固定 `core.fsmonitor=false`、`core.hooksPath=/dev/null`，diff 加 `--no-ext-diff --no-textconv`。

新測試建立真 Git repo，包含 `--output=should-not-exist`、`--config=other`、`-c`，改內容再經真 MCP read。Diff 成功，唔產生輸出檔、Git config bytes 不變；任意 raw option / write command 被 wrapper 拒絕。

## OAuth / pairing protection

沿用並實測 C2C 原有 guarantee：

- Pairing code 5 分鐘 TTL、一次性；新 code 取代舊 session。
- Cryptographically random code、hash / constant-time verification；每 session 最多 5 次錯誤，原有每 IP 10 次 / 分鐘。
- Explicit local pairing 先可以產生 authorization code；registration 唔會產生 token / Folder access。
- Authorization code 5 分鐘 TTL、一次性，PKCE S256；wrong verifier / consumed code / pairing replay 均失敗。
- 保留 access / refresh TTL、refresh rotation、scope filtering、revocation 同 Gate-bound bearer validation。

新增 repo-owned protection（Main 同 Side 均適用）：

- `/oauth/register` 每 socket address 20 次 / 分鐘；authorize / token / revoke 各 60 次 / 分鐘；各 route 有雙倍 Gate-wide budget。
- 唔信任 public X-Forwarded-For / CF headers 作限額身份，避免換 forged headers bypass。
- Rate-limit maps 上限 512 keys、過期清理；pairing IP map 亦有 512 entries cap。
- 每 Gate 最多 128 registrations；未授權 / abandoned registrations 10 分鐘後清理；有有效 access / refresh authorization 嘅 client 保留。
- 已授權而再冇有效 token 嘅 client metadata 最長保留 30 日；expired auth codes 清理。每分鐘同 OAuth requests 均執行 cleanup。
- Pending authorization requests最多 256 admission reservations / 10 分鐘，連 concurrent unfinished responses 一併計；配合 upstream pending request TTL。失敗 response 釋放 reservation。
- OAuth body 32KB；redirect URIs 最多 8 個、各 2048 chars；strings 最多 4096 chars；拒絕不合法 type。
- Invalid registration / pairing唔會產生新 persisted token；registration cap 會先拒絕，再寫 store。

Abandoned registration cleanup 唔影響仍有有效 refresh token 嘅既有 AI。上限滿時可以等過期 cleanup 或移除 inactive 登記，唔會自動踢走有效授權。

## Runtime / configure lock

`config.lock/owner.json` 用 private temporary file + rename；metadata 包括 PID、createdAt、unique token。相同目錄 inode / device 同 owner token 相符先由 owner 清理。Stale reclaim 有獨立 exclusive claim、再次核對目錄及 ownership，避免兩個 contender 同時清除。

- Active PID 永遠唔按 age reclaim；permission denied / 未能確定 owner alive 時亦唔當 dead。
- PID 確定不存在先 reclaim；missing / malformed metadata 用 30 秒 grace + mtime。
- Reclaim metadata 自身損壞亦可以恢復，唔留下永久鎖。

每個新 daemon 用 32 random bytes nonce（hex）及 startedAt。Runtime record、`/health`、private info 同 process argv 均包含同一 identity。Healthy 要求 Gate / service / nonce match，加 private admin token 驗證；private info 嘅 Gate / PID 亦核對。

Endpoint unavailable / foreign 時，只用同 UID、指定 daemon entrypoint、nonce arguments 作 ownership evidence；明確係 dead / unrelated process先安全清理舊 runtime。Unknown ownership 留記錄、回報 attention，唔 kill。Cleanup 比對 PID / admin token / nonce，舊 daemon唔會刪新 daemon record。Side decommission最後再核對 stopped，唔直接 unlink一個新 runtime。

Legacy runtime冇 nonce：只接受 matching health + authenticated private admin identity。Main reopening / Side managed status 可以安全停止舊 daemon，下一次開啟換新 core；唔撤銷正常 MCP authorization。

## Folder Passcode policy / temporary access

正式 policy：**Folder-level**，Main sharing toggle 同 Side membership 各自獨立。Side-only Folder 會建立 disabled Main registry policy metadata，唔會自動經 Main Gate 分享。缺失 / mismatched policy fail closed。

Side Gate唔再因 Passcode ON永久禁用。App Side detail reuse同一 Passcode popover；private `code-policy`、`folder-code`、`lock-folder` routes reuse同一 `FolderAccess`。Public MCP `unlock_workspace` 同 protected tool APIs同 Main。

每份 code / temporary key 均要求：

| Boundary | Runtime enforcement |
| --- | --- |
| Gate | 每 Gate 獨立 AuthStore、codes / grants；record 明確 gateID。Main token不能用於 Side、Side A token不能用於 Side B。 |
| Authorization | Key 綁定 OAuth access credential hash；另一 client / credential，即使知道相同 conversation ID亦不可讀。 |
| Folder | Folder ID、membership epoch、shared policy epoch 同現時 ACL均核對。 |
| Conversation | 優先 MCP `openai/session` metadata；冇 metadata 時明確提供 `session_id`。呢個係額外 binding，唔係單獨 credential，亦唔聲稱驗證咗 AI app 真實 chat identity。 |
| Expiry | Code 5 分鐘、single use；key最長 30 分鐘，唔超過 OAuth token expiry。 |
| Revoke | Revoke / Invalidate / Generate New Code立即清理該 Gate嘅 Folder codes / keys；policy開關改共享 epoch，Main / Side舊 grants一併失效。 |

所有 Folder operations，包括 Side原有 execution read tools，前後重新驗證 ACL同 key，in-flight revoke唔會返資料。Main unlock唔會傳到 Side。Main關閉分享唔會改 Side ACL；Remove Side Gate唔改 Folder policy / Main。

Temporary codes / keys只喺 daemon memory；restart需要重新產生 Folder code，**唔需要重新 pairing OAuth**。Side重用現有 C2C auth file；既有有效 Side operation-scope tokens仍須通過同一 Gate AuthStore / bearer middleware，唔會變跨 Gate授權。

## Packaging / diagnostics / assets

Bundle resources、Node、CLI缺失明確 fail，顯示缺少邊個 resource。Developer `#filePath` fallback只限非 bundled Debug，release唔會使用。

Gateway / Side CLI stderr保留 stack及可用嘅 underlying stderr；先遮罩 Bearer、token、secret、pairing / Folder codes、access keys、password / URL credentials。Swift記錄 exit status同sanitized stderr到私有 diagnostics目錄；stdout可能含 pairing code / file content，因此完全唔記錄。UI顯示簡短 message，唔直接dump stack。強遮罩可能亦遮罩較長 identifiers。

`build-new-user-app.sh` 依家亦複製新版 Git wrapper並保留 executable bit，避免 test bundle殘留舊 wrapper。

Assets audit：

- `Resources/AppIcon.png`：README及 build ICNS使用，保留。
- `Resources/ChatGPT Image 28 Sept 2026, 18_39_56.png`：packaging作 MenuBarArtwork，保留。
- `Resources/AppIcon-original.png`：可能係 design source；未能證明 accidental，保留。
- `ConnectionStatusView 2.swift`：Finder duplicate，excluded且無 legitimate reference，刪除。

## 本次修改檔案

以下只列本次 review有改動嘅檔案；working tree另有先前工作，冇重置或當成本次新增。

- `Package.swift`
- `Resources/Gateway/{access,diagnostics,launcher,oauth-security,registry,runtime-instance,server,side-lifecycle,side-registry}.mjs`
- `Resources/Gateway/git`
- `Resources/Tailscale/{owner-lock,provider}.mjs`
- `Sources/C2CManager/{C2CClient,C2CManagerApp,GatewayDiagnosticsLog,MainGateFolderPasscodeButton,RuntimePaths,SharedGatewayStore}.swift`
- 刪除 `Sources/C2CManager/ConnectionStatusView 2.swift`
- `Tests/Gateway/{diagnostics,gateway,git-security,oauth-security,passcode-gates,runtime-instance,side-lifecycle}.test.mjs`
- `Tests/Tailscale/owner-lock.test.mjs`
- `Tests/C2CManagerTests/{GatewayDiagnosticsLogTests,RuntimePathsTests}.swift`
- `scripts/build-new-user-app.sh`
- `docs/product-model-architecture-invariants-v1.md`
- `docs/gate-contract-v1-implementation.md`（標示舊暫行方案已被取代）
- 本文件

## 測試 / build

| 驗證 | 結果 |
| --- | --- |
| Debug build | PASS |
| Swift tests：resource / diagnostics / existing lifecycle / UI status | 58 / 58 PASS |
| Node Gateway / Tailscale tests，包括本次 security regression | 77 / 77 PASS |
| 真 Main + Side daemon、legacy auth migration、decommission / re-add | PASS |
| MCP Git特殊 filenames：actual Git讀取、無寫檔 / config mutation | PASS |
| OAuth abuse / pairing TTL / replay / PKCE / pending cap | PASS |
| Active contention / dead owner / missing / malformed / stale reclaim | PASS |
| Reboot / PID reuse / foreign health / nonce mismatch / owner-only cleanup | PASS |
| Main / Side protected read、unlock隔離、expiry / immediate revoke / Off ACL | PASS |
| 0 Folder startup / pair / reconnect / crash recovery regression | PASS |

Node integration使用 bundled C2C **0.1.3** / MCP SDK **1.30.0**，包括本機 HTTP MCP、真 Git、真 Side daemon subprocess同 legacy C2C daemon；provider external reachability用 fixture，不會登入 / 登出用戶帳戶。

## Verification boundary / 下一步

外部 `/Users/developer/codex-with-chatgpt` source及 bundled compiled modules已 inspect；冇修改外部 repo。本次 adapter / wrapper針對 App-managed Main及 Side。獨立直接執行 upstream C2C CLI唔會自動取得新增 OAuth限額 / nonce / Folder policy保護。

未聲稱驗證未來版本 backend相容性、真 public Tailscale / Cloudflare網絡可達、AI網站 live request或完整 manual UI。保留已有 Tailscale及 Cloudflare named / quick選擇、固定 endpoint身份，冇 provider migration。

新版 Debug app套用到既有 Gate時，要重新開啟 Gate一次以載入新 daemon；既有 OAuth配對保留。Release archive未發佈 / 更新，冇改真用戶資料或停止現有 production Gate。
