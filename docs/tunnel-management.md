# Tunnel 管理入口

## 正常 flow

Secure Access inline 顯示真正下一步：Set Up、Sign In、Continue Authorization 或 Repair。正常時顯示 `Tailscale · Connected`，Recheck／Sign Out 收入該 stage 嘅 `…`。Server URL 主要放喺 Connect an AI App；技術資料同既有管理頁降級為 Advanced → Advanced Tunnel Details。

Open Gate 只開 local MCP／OAuth host。Secure Access 必須由明確操作啟動；background refresh／reconnect 唔會要求互動登入。Provider preflight 同 endpoint checks 係 source of truth，毋須 Done confirmation。

## 共用內置 Tunnel

新 Main／Side Gates 共用一個 private Tailscale agent／account，Side Gate 使用獨立 URL path、route nonce 同 MCP authorization。新增 Side Gate 唔需要重複登入；已登入時 Set Up 只啟用該 Gate route。既有獨立 Side endpoint 必須明確 migration，唔會靜默改 URL。

登出共用帳戶前需確認會影響共用該 Tunnel 嘅 Gates。普通登出唔撤銷 MCP authorizations、Folder membership 或 Passcode policy。停止／移除單一 Gate 只清該 Gate runtime／route，唔登出其他 Gate。

外置模式沿用 Mac LocalAPI；登出前保留 confirmation，因為會影響同一裝置其他服務。內置模式毋須另裝外置 Tailscale。登入另一帳戶而 hostname 不符仍會被既有 URL mismatch guard 拒絕，唔偷偷改 Server URL。

## DNS／repair

本機 DNS failure 唔會當成登入失敗，亦唔會反覆重啟正常 route。Repair network cache 需要明確確認；詳見 [Secure Access DNS troubleshooting](secure-access-dns-troubleshooting.md)。

實作、隔離／migration tests 同收貨結果見：

- [Shared Tunnel implementation](shared-tunnel-implementation.md)
- [Main Gate setup journey](main-gate-setup-journey.md)
- [Side Gate setup journey](side-gate-setup-journey.md)
- [Acceptance — 2026-10-09](acceptance-2026-10-09.md)
