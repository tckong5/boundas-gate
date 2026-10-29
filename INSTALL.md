# Boundas Gate 1.2.1

支援 Apple Silicon Mac，macOS 14 或以上。

## 安裝

1. 喺 DMG 將 **Boundas Gate.app** 拖入 Applications；ZIP 版本先解壓縮，再將 app 移入 Applications。
2. 開啟 Boundas Gate，按 **Add Folder** 加入要分享嘅資料夾。
3. 揀 **Main Gate** 或建立 **Side Gate**，按 **Open Gate** 啟動本機 Gate。
4. 喺 **Secure Access** 按 **Sign In**／**Set Up**，完成 Tailscale secure access。Fresh/current Shared Secure Access 只需一次 Tailscale login；新增 Folder 或 Side Gate 唔需要重複登入。Existing legacy fixed-address／external transport 會保留到明確 migration，唔會靜默改 endpoint 或 device identity。
5. 喺 **Connect an AI App** 揀 ChatGPT、Claude 或其他 MCP-compatible app，跟住畫面指示完成 MCP Connection。
6. 見到 **Ready to Use** 即代表呢個 Gate 已完成 setup。

ChatGPT setup 會引導你：

1. Open Plugins
2. Click Add +
3. Choose Create MCP App

之後喺 ChatGPT 貼入 Boundas Gate 顯示嘅 Name、Description 同 Server URL，按要求完成 authorization。Claude 或其他 MCP app 使用各自獨立嘅 MCP Connection。

## Main Gate 同 Side Gate

Main Gate 可以分享 0 個或多個 Folder。Side Gate 係獨立嘅 Gate，加入 Folder、Open／Close、Secure Access 同 MCP authorization 都獨立管理。同一 Folder 可以同時出現喺 Main Gate 同 Side Gate；Remove Side Gate 唔會刪除 Folder 或改 Main Gate。

## 升級現有 Boundas Gate

先退出舊 app，再以新版本取代 Applications 入面嘅 app。Folder、Gate state、OAuth authorization、Tailscale state 同 endpoint metadata 會留喺：

```text
~/Library/Application Support/Boundas Gate
```

Bundle identifier 只係 macOS app identity，唔係 Gate identity；升級唔會因為 bundle ID 改變而另開一個 Gate。首次正式 production 啟動會按現有 migration 規則安全處理舊資料；Debug 同 New User Test 使用獨立 profile，唔會遷移 production state。
Bundle identifier 只係 macOS app identity，唔係 Gate identity；升級唔會因為 bundle ID 改變而另開一個 Gate。首次正式 production 啟動會按現有 migration 規則安全處理舊資料；Debug 同 New User Test 使用獨立 profile，唔會遷移 production state。Existing legacy fixed-address／external transport 會維持原有 endpoint 同 device identity，直到 user 明確執行 migration。

## Runtime 同安全

Node.js、C2C backend、cloudflared 同 Tailscale userspace runtime 已經隨 app 包含，普通用戶唔需要另外安裝 Homebrew、Node、C2C 或 Tailscale App。Runtime 內嘅第三方元件保留各自 license；根目錄 LICENSE 只適用於 Boundas Gate 自己嘅程式碼。

Folder Passcode Protection 係額外 Folder-level policy。開啟後，經 Main Gate 或 Side Gate 存取該 Folder 都需要遵守同一 policy；Temporary Access、expiry 同 revoke 狀態會喺 Passcode popover 顯示。

## 本版本驗收狀態

本機／測試 build 使用 ad hoc signing，未等同 Developer ID public release。正式 release path 需要：

- `BOUNDAS_CODESIGN_IDENTITY`
- `BOUNDAS_NOTARY_PROFILE`（`xcrun notarytool` Keychain profile）
- Developer ID Application certificate、hardened runtime、notarization、stapling 同 Gatekeeper verification

如未提供 credentials，public mode 會直接停止，唔會產生看似已準備好嘅 public artifact。正式 release status 見 [RELEASE_NOTES.md](RELEASE_NOTES.md)。
