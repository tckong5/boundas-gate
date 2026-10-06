# Boundas Gate 1.2.0 試用版

支援 Apple Silicon（M1／M2／M3／M4 等）Mac，macOS 14 或以上。

## 安裝

1. 開啟 DMG，將 Boundas Gate 拖入 Applications；ZIP 版本先解壓縮再移入 Applications。
2. 開啟 Boundas Gate，按 Add Folders… 加入你想分享嘅資料夾。
3. 喺「共用 ChatGPT 連線」勾選資料夾，按「儲存變更」。
4. 按「登入內置連線」，用你自己嘅 Tailscale 帳戶登入。需要 HTTPS／Funnel 權限時，按 App 提供嘅授權連結。
5. 開啟共用連線，複製 MCP URL，喺 ChatGPT 新增 OAuth 連線並輸入 App 產生嘅配對碼。

Node.js、C2C backend、Tailscale 連線核心已內置；共用模式唔需要 Homebrew、Terminal 或另外安裝 Tailscale App。

本試用包使用本機 ad hoc 簽署，未經 Apple Developer ID 簽署／公證。首次開啟可能需要按 macOS「私隱與保安」頁面嘅「仍要打開」確認。

## 已有 Boundas Gate

先退出舊 App，再換入新版。資料夾、分享清單、OAuth 授權同固定地址保存喺 Application Support，唔會隨 App 替換而清除。

已有固定地址嘅連線繼續使用原本 Tailscale App／裝置，避免 URL 改變。1.2.0 唔會自動將舊連線切換成新嘅內置裝置身份。新安裝使用內置連線。

配對一次後，新增 Folder 並確認分享即可；取消分享即時撤銷該 Folder 存取。選用 Folder 通行碼仍需逐個解鎖。

## 驗證範圍

已驗證內置 runtime 喺空白 HOME／冇 system Node 路徑嘅隔離環境運作、內置核心啟動及登入流程；本機 OAuth／MCP、動態授權、路徑限制、公開路由同舊 URL 保護有自動測試。

完整內置 Funnel 連線需要本人登入後實測；唔等同已喺另一部實體 Mac、VPN 切換或全新 ChatGPT 帳戶完成驗收。自動更新及正式公開發佈仍係下一階段。

## 更新

目前版本未有 App 內自動更新。替換 App 後，原有分享設定同有效 OAuth 授權可繼續使用。
