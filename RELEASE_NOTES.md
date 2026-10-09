# Boundas Gate 1.2.0（production build 7）

目前係 release candidate。產品版本維持 1.2.0；production build number 由 6 提升至 7。

## 今輪完成

- Main Gate / Side Gate 使用一致嘅 Gate、Folder、Tunnel 同 MCP Connection model。
- Fresh/current Shared Secure Access 讓 Main Gate 同 Side Gate 共用 Tailscale identity，但 route、lifecycle、authorization boundary 彼此獨立；existing legacy fixed-address／external transport 會保留到明確 migration。
- Secure Access、Connect an AI App 同 Ready to Use 統一成 current setup journey。
- Live Gate Activity Map 顯示 Gate、AI app、Folder topology 同 request activity。
- Side Gate runtime state 由單一 owner 管理，避免重複 start、refresh、reconnect 或 stale state。
- Boundas Gate branding 已完成；bundle identifier 改為 `com.boundasgate.app`。Production state migration implementation 同 fixture verification 已完成，真實 production migration 仍待 final acceptance；Gate identity 仍由既有 Gate state 提供。
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

| 項目 | 結果 |
| --- | --- |
| Swift suite | PASS，128 tests |
| Gateway／Tailscale Node suite | PASS，101 tests |
| Go tunnel tests | PASS，`go test -race ./...` |
| Local/test ad hoc signing path | PASS；bundle / ZIP extracted app `codesign --verify --deep --strict` 通過 |
| Developer ID signing path | 已實作；需要 `BOUNDAS_CODESIGN_IDENTITY` |
| Notarization / stapling / Gatekeeper | 未執行；需要 `BOUNDAS_NOTARY_PROFILE` 及 Developer ID credentials |
| Portable release smoke test | PASS；isolated bundle、embedded userspace core、login URL、retry identity 全部通過 |

未有喺今輪執行真實 production migration，亦未接觸真實 Folder、OAuth token 或 Tailscale account。

## Public release path

本地測試可以使用 ad hoc signing：

```sh
./scripts/build-app.sh
./scripts/package-release.sh
```

正式 public path 必須提供：

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

如有 Developer ID certificate 及 notarytool profile，先可以做真正 public release acceptance；完成 acceptance 後先執行真實 production migration。今輪唔會自行做 production data migration。
