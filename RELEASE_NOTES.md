# Boundas Gate 1.2.0（production build 7）

目前係未發布嘅 open-source public beta candidate，**ad-hoc signed、未 Apple notarized**。產品版本維持 1.2.0，production build number 係 7。

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
| Developer ID signing path | 已實作；需要 `BOUNDAS_CODESIGN_IDENTITY` |
| Notarization / stapling / Gatekeeper | 未執行；需要 `BOUNDAS_NOTARY_PROFILE` 及 Developer ID credentials |
| Portable release smoke test | PASS；isolated bundle、embedded userspace core、login URL、retry identity 全部通過 |

Production migration、production MCP read 同 quit／reopen identity continuity 已驗收。今次 pre-public repository cleanup 冇接觸 production data／runtime。

## Public release path

本地測試可以使用 ad hoc signing：

```sh
./scripts/build-app.sh
./scripts/package-release.sh
```

選用 Developer ID／notarization mode 時必須提供以下設定；目前 ad-hoc public beta candidate 未使用呢個 mode：

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

完成 repo privacy／artwork 授權確認，設定正式 appcast URL，再另行批准 GitHub repository／release 發布。Production migration 已完成，唔需要重做。Developer ID／notarization 留待另一次明確批准嘅 release 工作。
