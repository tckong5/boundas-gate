# Boundas Gate

<img src="Resources/AppIcon.png" width="128" alt="Boundas Gate icon">

> Give an AI app access to selected local Folders without giving it access to the whole Mac.

Boundas Gate 係 macOS 原生 app。你可以揀要分享嘅 **Folder**，再由一個 **Main Gate** 或獨立嘅 **Side Gate** 對外提供 MCP endpoint。Gate、Tunnel、MCP Connection 同 Folder 係分開管理；Gate 可以冇 Folder，亦可以喺未授權任何 AI app 時保持運行。

## 目前使用流程

```text
Add Folder
    ↓
Main Gate / Side Gate
    ↓
Open Gate
    ↓
Secure Access
    ↓
Connect an AI App
    ↓
Ready to Use
```

1. 用左邊 **Add Folder** 加入資料夾。Main Gate 加入 Folder 唔會自動建立 Side Gate；Side Gate 亦要明確加入。
2. 選擇 Main Gate 或 Side Gate，按 **Open Gate**。呢一步只啟動本機 Gate。
3. 喺 **Secure Access** 按 **Sign In**／**Set Up**。Fresh/current Shared Secure Access 只需完成一次 Tailscale login；Main Gate 同 Side Gate 共用同一個 Tailscale identity，但每個 Gate 有自己嘅 route 同 MCP authorization。Existing legacy fixed-address／external transport 會保留到你明確執行 migration，app 唔會靜默改 endpoint 或 device identity。
4. 喺 **Connect an AI App** 揀 ChatGPT、Claude 或其他 MCP-compatible app，跟住畫面入面嘅 setup instructions。
5. 完成授權後，畫面會顯示 **Ready to Use**。已完成 onboarding 嘅 Gate，即使之後變成 0 MCP Connections，仍會保留正常 empty state，而唔會被當成首次設定。

### ChatGPT setup

現時 ChatGPT setup 會引導你：

1. Open Plugins
2. Click Add +
3. Choose Create MCP App

之後按頁面嘅 Name、Description、Server URL 同 authorization 指示完成連線。URL 只喺 **Connect an AI App** 顯示；Secure Access 只負責「外面可唔可以到達 Gate」。

Claude 同其他 MCP app 使用同一個 Gate model，但各自嘅 MCP Connection、token 同 authorization boundary 互不共用。

## Gate、Folder 同 authorization

- **Main Gate** 可以有 0..n Folders。
- **Side Gate** 係一個獨立管理嘅 Gate，預設只提供一個明確加入嘅 Folder。
- 同一個 Folder 可以同時屬於 Main Gate 同 Side Gate；移除 Side Gate 唔會刪除 Folder 或改 Main Gate。
- 每個 MCP Connection 只屬於一個 Gate。Authorized 只代表 authorization 存在，唔代表有 live session。
- Gate health 係 Local + Secure Access；MCP Connections 同 Folder sharing 係獨立資訊。
- Folder Passcode Protection 係 Folder-level policy。Folder 經 Main Gate 或 Side Gate 暴露時，都必須遵守同一政策。

詳細 product contract、Side Gate lifecycle 同 shared tunnel model：

- [Product model invariants](docs/product-model-architecture-invariants-v1.md)
- [Side Gate runtime owner](docs/side-gate-runtime-owner.md)
- [Secure Access / tunnel journey](docs/tunnel-management.md)
- [Security robustness review](docs/security-robustness-review.md)

## Secure Access

Secure Access 係 user-facing Tunnel management。Fresh/current Shared Secure Access 正常只顯示 provider 同 ready 狀態，例如 `Tailscale · Connected`；低頻嘅 Recheck、Sign Out 同 technical diagnostics 收喺 `…` 或 Advanced。Main Gate 同 Side Gate 共用 Tailscale identity，但每個 Gate 使用獨立 URL path、route ownership 同 authorization。Existing legacy fixed-address／external transport 會保留到明確 migration；唔會靜默改 existing endpoint 或 device identity。

App 內置 Node.js、C2C backend、cloudflared 同 Tailscale userspace runtime。實際 bundle 亦保留 Node、C2C、cloudflared、Go／Tailscale 依賴嘅 license 文件；根目錄 [LICENSE](LICENSE) 只適用於 Boundas Gate 自己嘅程式碼。

## Window、Quit 同更新

關閉主視窗只會關閉 UI；Gate 繼續運行，可以由 menu bar 嘅 **Show Boundas Gate** 返回。**Quit Boundas Gate** 會依次停止 Side Gates、Main Gate 同已驗證屬於當前 profile 嘅 bundled helper，再退出 app；保留 desiredRunning、Folder、OAuth 同 Tailscale identity，下一次啟動可以重用既有設定。

Main Gate external → Shared Secure Access 嘅明確 migration、production MCP read 同重啟 identity continuity 已驗收。既有 external endpoint 仍只會由用戶明確批准 migration，唔會靜默更換。

v1.2.1 亦支援 Folder rename／move 後保留原有 Folder identity；呢項係 v1.2.0 發布後加入，v1.2.0 release 本身未包含。

Sparkle 2.10 更新整合已完成，menu bar 提供 **Check for Updates…** 同原生 **About Boundas Gate…**。Update archive 必須通過 EdDSA 驗證；私鑰只留喺 Login Keychain。目前正式 appcast URL 尚未設定，未設定 feed 嘅 build 唔會啟動更新檢查。發布設定及隔離測試方法見 [UPDATES.md](docs/UPDATES.md)。

## Passcode Protection

Folder row 永遠顯示固定嘅 password-lock icon。icon 只表達 Passcode Protection policy On／Off，唔會因 temporary unlock 變成 open lock。Popover 會分開顯示：

- Protection policy：Passcode Protection On／Off
- Temporary access：Protected、Temporarily Unlocked、expiry 同 revoke action

Passcode 係額外 Folder-level protection，唔代表 Off 時 Folder 沒有 Gate protection。詳細 capability、expiry 同撤銷規則見 [product model](docs/product-model-architecture-invariants-v1.md)。

## 資料與 profile

正式 app 使用：

```text
~/Library/Application Support/Boundas Gate
```

New User Test 使用獨立嘅 `Boundas Gate New User Test` profile。Raw Debug executable 預設使用 `Boundas Gate Debug`，唔會讀取或遷移 production state。只有 DEBUG build 明確設定 `BOUNDAS_DATA_PROFILE=production` 先會 opt in 到 production profile；New User Test 會忽略呢個 override。

App 會保留 existing Gate identity、OAuth、Tailscale state 同 Folder records；bundle identifier 唔係 Gate identity。首次安裝／升級嘅 migration 只喺正式 production profile 進行，唔會喺 debug 或 test profile 觸碰真實資料。

## Build、測試同 release

本地／測試 build 保留 ad hoc signing：

```sh
./scripts/build-app.sh
./scripts/package-release.sh
./scripts/build-new-user-app.sh
```

release identity 集中喺 [`scripts/release-config.sh`](scripts/release-config.sh)：product name、bundle ID、版本同 production build number 由同一份設定提供。現行公開 release 係 **1.2.1**；production build number 係 **8**。套件已發布到 [GitHub Releases](https://github.com/tckong5/boundas-gate/releases/tag/v1.2.1)，使用 ad-hoc signing、未 Apple notarized；macOS Gatekeeper 可能需要手動選擇 Open Anyway。Developer ID／notarization 係可選嘅未來 release path，並非目前安裝要求。

**1.2.1（build 8）** 修正 macOS filesystem identity recovery 同 Gateway／WorkspaceStore identity 同步，保留既有 Gate、OAuth 同 Passcode 設定。

正式 Developer ID path 必須明確要求簽名及公證 credentials，唔會靜默退回 ad hoc：

```sh
BOUNDAS_BUILD_MODE=public \
BOUNDAS_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
BOUNDAS_NOTARY_PROFILE="boundas-release" \
./scripts/build-app.sh

BOUNDAS_BUILD_MODE=public \
BOUNDAS_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
BOUNDAS_NOTARY_PROFILE="boundas-release" \
./scripts/package-release.sh
```

`BOUNDAS_NOTARY_PROFILE` 係 `xcrun notarytool` Keychain profile 名稱。private key、Apple ID password 同 app-specific password 唔可以放入 repo。Public path 會用 hardened runtime、timestamp、nested Mach-O signing、notarization、stapling、`codesign` 同 `spctl` verification；冇 credentials 時會直接 fail。Bundled Node/V8 只使用 `com.apple.security.cs.allow-jit`，因為實測 hardened runtime 下冇呢項會令 Node CodeRange 初始化失敗；其他 runtime executable 唔加額外 entitlement。

`dist/` release output 只保留：

```text
Boundas Gate.app
Boundas-Gate-1.2.1-arm64.zip
Boundas-Gate-1.2.1-arm64.dmg
SHA256SUMS.txt
```

New User Test 只輸出到 `.build/apps/Boundas Gate New User Test.app`，唔會放入 `dist/`。

## 測試

```sh
swift test
node --test Tests/Gateway/*.test.mjs Tests/Tailscale/*.test.mjs
(cd Native/Tunnel && go test ./...)
```

Gateway integration tests 需要提供已驗證嘅 `BOUNDAS_C2C_ROOT`。Portable release smoke test 會喺隔離 HOME 及 temporary state 執行，唔會改真實 production profile。

## License

Boundas Gate 自己嘅程式碼使用 MIT License。Node、C2C、cloudflared、Go、Tailscale 同 Sparkle 元件仍然受各自 upstream license 約束；請參閱 packaged Runtime 入面嘅 license 文件。Artwork 嘅公開散佈授權確認狀態見 [artwork provenance](docs/artwork-provenance.md)，唔應由 source code 嘅 MIT License 推斷第三方素材權利。

## 歷史文件

`docs/` 內保留 acceptance、migration、security review 同 architecture contract，當中若有 historical release notes，會標明當時版本及驗收範圍；唔應視為目前 UI workflow。當前 release status 見 [RELEASE_NOTES.md](RELEASE_NOTES.md)。
