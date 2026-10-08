# Boundas Gate acceptance — 2026-10-09

## 收貨及 freeze

目前產品行為已收貨並凍結。今輪只整理 repo history；Activity Map curvature、breathing、AI icon 同其他 visual polish 留待下一輪。

使用最新 source 執行 `scripts/build-new-user-app.sh`，收貨 App 為：

`dist/Boundas Gate New User Test.app`（build 45，獨立 new-user-test data profile）。

只啟動上述 packaged App，沒有以 raw `.build/debug/C2CManager` 做 smoke test。確認 Runtime/bin 嘅 `boundas-tunnel`、`node`、`cloudflared` 齊備且可執行；Resources/Gateway 同 Resources/Tailscale 與最新 source 逐檔一致。

## Packaged smoke test

| 項目 | 結果／證據 |
| --- | --- |
| Main Gate local Open／Close | PASS；Close 保留原有 Folders／MCP authorization；Open 只啟動 local host，未偷偷要求 Tailscale login |
| Secure Access | PASS；明確 Set Up 後共用內置 Tailscale route 正常，Gate Open |
| Existing MCP authorization | PASS；原有 ChatGPT authorization 於 Close／Open 同 quit／reopen 後保留 |
| New MCP authorization | PASS；以 disposable MCP client 經 packaged service 真實 registration、pairing、OAuth PKCE 及 token exchange |
| Add Folder／Main sharing | PASS；隔離 Folder 經 Add by Path 加入並儲存分享；Main／Side membership 可各自操作 |
| Live Map topology | PASS；effective AI／Folder nodes 同 Gate→Folder connectors 正常 |
| Real MCP traffic | PASS；6 次真實 read_file／search_workspace，包含 public HTTPS read；6 個 requestStarted／requestFinished 成功事件；目測 request photon、active Folder 及 response／AI arrival 提示 |
| Completed onboarding 後 0 MCP Connections | PASS；撤銷 disposable client 後仍 Gate Open，顯示空 map 同 Connect an AI App，沒有重返 first-run |
| Side Gate Open／Close | PASS；新 Side 使用已登入嘅共用 Tailscale，毋須第二次 login；Close 只影響該 Gate，Main 及其他 Side 保持運行 |
| Folder Passcode policy | PASS；fixture policy On 時未有 access key 嘅 read 被拒絕；invalidate／Off 後同一 read 可成功；測試後還原 Off |
| Quit／reopen | PASS；packaged App 重開後恢復 Gate Open、原有 ChatGPT authorization 及兩個原有 Main Folders |
| Fixture cleanup | PASS；測試 Side Gate decommission 後 Folder 仍存在，最後移除測試 Folder；原有 auth backup 原樣還原並核對 client identities；temporary credentials／Folder 已清理 |

新 authorization 係真實 OAuth／MCP 測試 client，唔係假 UI state；以上唔聲稱已做第三方 ChatGPT／Claude app 嘅完整人工 onboarding 或 live-session health test。

## 收貨發現及限定修正

1. **Map Folder connector 缺少 path origin**：empty static Path 要先 move 到 Gate，再加同一條 cubic Bézier。補 geometry regression test，沒有改 curvature／topology。
2. **Fast request arrival 提示缺失**：Folder arrival 覆蓋 response phase，以 requestID 去重，避免快 request 跳過 waiting 時冇 arrival pulse。Telemetry／concurrency semantics 保持原樣。
3. **Folder path alias 與 server canonical path 不同**：新增 Folder 改用 filesystem realpath 作 record path／ID，避免 `/tmp` 同 `/private/tmp` 差異令分享失敗。補 symlink canonicalization／deduplication regression test。
4. Packaging script 設為 executable，保留現有 bundle profile／resources；build number 同 build date 明確標記新 package。

## 測試及 build

- Swift：103 tests，0 failures。
- Node Gateway／Tailscale：97 tests，0 failures。
- Go Tunnel：全部通過。
- Debug build：成功。
- 現有 portable runtime smoke：用同一 New User Test bundle 嘅乾淨隔離 copy 通過，簽章有效、毋須 system Node／C2C；fresh embedded core 同 login retry 保留 identity。
- 每組 coherent commit 以 staged tree 匯出隔離 snapshot，逐組驗證 Debug 可 build；Native／Gateway snapshot 另跑相應 suite。
- Cleanup 完成後再跑上述完整 suites 及 Debug build；最終結果以本次交付報告為準。

測試覆蓋 0 Folder startup／pair／reconnect、Side membership／decommission／retry、Gate authorization isolation、Passcode policy、MCP revoke、shared route nonce／port reuse、DNS reconnect guards、setup persistence，同 activity privacy／concurrency／Reduce Motion。

## Obsolete source

以下三個舊 view 已被共用 journey 取代，冇剩餘 call site，今輪正式記錄刪除：

- Sources/C2CManager/ConnectionRepairGuide.swift
- Sources/C2CManager/ConnectionStatusView.swift
- Sources/C2CManager/StableConnectionView.swift

`MainGateFolderPasscodeButton.swift` 改名為 `FolderPasscodeButton.swift`，沿用原有實作並共用於 Main／Side Gate。

其他 modified／untracked source、tests 同 docs 均屬於已完成工作。`.build`、`dist`、本機 credentials、測試 scripts／logs 及 screenshot captures 沒有加入 Git。

## 已知交付限制

Repo 位於 macOS Documents File Provider：最終 app copy 可能被系統重新加入 FinderInfo／File Provider extended attributes，令該位置嘅 strict codesign verification 報 resource-fork metadata。Script staging signature verification 通過，最終指定 dist App 實際可啟動，resources bytes 已核對。這是本機 filesystem metadata 限制，唔係 MCP／Tunnel 功能未完成；今輪沒有為此改系統設定。

没有功能 blocker 留低。沒有新增 provider framework／ngrok、沒有 push、沒有另開 branch。
