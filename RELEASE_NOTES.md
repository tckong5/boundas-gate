# Boundas Gate 1.2.1（production build 8）— 已發布

此 bug-fix release 已完成 Production 驗收，GitHub Release：
[Boundas Gate v1.2.1](https://github.com/tckong5/boundas-gate/releases/tag/v1.2.1)。

## 修正

- 修正 macOS 重啟／重新掛載後 filesystem device ID 改變，令原有 Folder 被錯誤拒絕分享嘅問題。只會喺原有 bookmark 成功驗證、路徑及 inode 符合安全檢查後恢復 identity。
- WorkspaceStore 將已驗證嘅 identity recovery 同步到 Gateway registry，保留 Folder UUID、c2cID、Gate 設定、MCP URL、OAuth credentials、Passcode policy 同 authorization epoch；同步唔會將停用嘅 Folder 自動重新分享。
- 保留 fail-closed：Folder 被替換、身份未能確認，或缺少有效 recovery 證據時仍然拒絕存取；唔會單靠相同 inode 接受新 Folder。
- 修正 Main Gate 儲存失敗時只短暫 loading、冇清楚回饋嘅問題，並提示需要重新定位嘅 Folder。
- 包含 v1.2.0 發布後已完成嘅 Folder relocation 支援；移動／重新命名仍保留既有身份及授權。

## Release identity／驗證

- Version：`1.2.1`；production build：`8`；bundle identifier：`com.boundasgate.app`。
- 使用既有 **ad-hoc signing、未 Apple notarized** 發布方式。macOS Gatekeeper 可能需要手動選擇 Open Anyway；Developer ID／notarization 刻意暫緩，唔係本版本嘅發布 blocker。
- Sparkle integration 保留；production appcast／update feed 尚未啟用。
- Identity hotfix 必要檢查已通過：原 Folder remount recovery、replacement rejection、Gateway／WorkspaceStore 同步及既有 policy 保留。Production v1.2.1 已驗收 Gateway、既有 Folder、authenticated MCP read 同 Main Gate 儲存。
- Release 由已驗證嘅隔離 source snapshot 建立，只納入已完成嘅 identity hotfix 同必要版本／說明資料。

## Release artifacts

```text
Boundas-Gate-1.2.1-arm64.zip
Boundas-Gate-1.2.1-arm64.dmg
SHA256SUMS.txt
```

---

# Boundas Gate 1.2.0（production build 7）— 已發布

v1.2.0 係已發布嘅 open-source public beta，GitHub Release：
[Boundas Gate v1.2.0](https://github.com/tckong5/boundas-gate/releases/tag/v1.2.0)。
此版本係 **ad-hoc signed、未 Apple notarized**；macOS Gatekeeper 可能需要用戶手動選擇 Open Anyway。
產品版本係 1.2.0，production build number 係 7。

## 今輪完成

- Main Gate / Side Gate 使用一致嘅 Gate、Folder、Tunnel 同 MCP Connection model。
- Fresh/current Shared Secure Access 讓 Main Gate 同 Side Gate 共用 Tailscale identity，但 route、lifecycle、authorization boundary 彼此獨立；existing legacy fixed-address／external transport 會保留到明確 migration。
- Secure Access、Connect an AI App 同 Ready to Use 統一成 current setup journey。
- Live Gate Activity Map 顯示 Gate、AI app、Folder topology 同 request activity。
- Side Gate runtime state 由單一 owner 管理，避免重複 start、refresh、reconnect 或 stale state。
- Boundas Gate branding 已完成；bundle identifier 係 `com.boundasgate.app`。Production state migration 同 Main Gate external → Shared Secure Access migration 已完成並驗收；既有 Gate identity、Folder settings、OAuth 同 embedded identity continuity 保留。
- Production MCP read acceptance 同 clean quit／reopen acceptance 已完成。
- 關閉視窗只關 UI；menu bar Quit 會依次停止 Side、Main 同已驗證 helper，保留 desiredRunning 同所有 persistent identity／authorization。
- Sparkle 2.10、Check for Updates 同原生 About panel 已完成；使用 EdDSA-signed archives。正式 appcast URL 尚待設定／發布，冇 feed 嘅 build 唔會自動檢查。
- Workspace state fail closed：corrupt config、invalid Folder identity、duplicate Folder identity、duplicate canonical path 或 c2cID collision 都會停止啟動，唔會當成空白 Folder list。
- Raw Debug 預設使用 `Boundas Gate Debug` profile；New User Test 使用獨立 profile，唔會讀取 production state。
- Root `LICENSE` 加入 Boundas Gate MIT License；Runtime 內第三方 license 保持分開。
- Local/test build 同 public Developer ID / notarization path 分開；public mode 缺少 credentials 時會直接 fail，唔會退回 ad hoc signing。
- Node/V8 hardened-runtime entitlement 已經以實測收窄至 `com.apple.security.cs.allow-jit`；冇加入 broad executable-memory 或其他額外 entitlement。

## v1.2.0 發布後進展

- Folder relocation 已加入 main（commit `8bc7f59`），並包含於 v1.2.1：Folder rename／move 可以保留原有 UUID、c2cID、Gate、OAuth 同 passcode policy。呢項不屬於 v1.2.0 release asset。
- Local Network permission investigation 暫時冇需要修改 Boundas code；舊 Tailscale Network Extension 係主要懷疑來源，但停用後重開機驗收仍待完成，未宣稱根因已 conclusively verified。

## Release identity

| 項目 | 值 |
| --- | --- |
| Product | Boundas Gate |
| Bundle identifier | `com.boundasgate.app` |
| New User Test bundle identifier | `com.boundasgate.app.new-user-test` |
| Version | `1.2.0` |
| Production build | `7` |
| License | MIT（只適用於 Boundas Gate 自己嘅程式碼） |

## 驗收狀態

以下完整 suite counts 保留作 release-preparation baseline，唔代表每次後續 commit 都重跑完整 suite；後續 migration、Quit 同 Sparkle 使用相關 focused tests／packaged checks。

| 項目 | 結果 |
| --- | --- |
| Swift suite | PASS，128 tests |
| Gateway／Tailscale Node suite | PASS，101 tests |
| Go tunnel tests | PASS，`go test -race ./...` |
| Local/test ad hoc signing path | PASS；bundle / ZIP extracted app `codesign --verify --deep --strict` 通過 |
| Developer ID signing path | 已實作但刻意暫緩；需要 `BOUNDAS_CODESIGN_IDENTITY` |
| Notarization / stapling / Gatekeeper | 未執行；需要 `BOUNDAS_NOTARY_PROFILE` 及 Developer ID credentials |
| Portable release smoke test | PASS；isolated bundle、embedded userspace core、login URL、retry identity 全部通過 |

Production migration、production MCP read 同 quit／reopen identity continuity 已驗收。今次 pre-public repository cleanup 冇接觸 production data／runtime。

## Public release path

本地測試可以使用 ad hoc signing：

```sh
./scripts/build-app.sh
./scripts/package-release.sh
```

選用 Developer ID／notarization mode 時必須提供以下設定；目前已發布嘅 ad-hoc public beta 未使用呢個 mode：

```sh
BOUNDAS_BUILD_MODE=public
BOUNDAS_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
BOUNDAS_NOTARY_PROFILE="boundas-release"
```

`BOUNDAS_NOTARY_PROFILE` 係 `xcrun notarytool` Keychain profile 名稱。Public path 會簽 nested Mach-O、使用 hardened runtime 同 timestamp、submit／wait notarization、staple、再做 `codesign` 同 `spctl` verification。任何 credential 缺失都會停止，唔會報告 release ready。

## dist 內容

正式 package 完成後，`dist/` 只應包含：

```text
Boundas Gate.app
Boundas-Gate-1.2.0-arm64.zip
Boundas-Gate-1.2.0-arm64.dmg
SHA256SUMS.txt
```

New User Test 會留喺：

```text
.build/apps/Boundas Gate New User Test.app
```

## 下一步

後續可選工作係設定正式 appcast URL，另行產生及發布 Sparkle signed updates；目前 feed 未啟用。Production migration、production MCP read、Quit／reopen 同 Folder relocation acceptance 已完成，唔需要重做。Developer ID／notarization 因未加入 Apple Developer Program 而刻意暫緩；v1.2.1 release 見本文開首。
