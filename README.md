# Boundas Gate

<img src="Resources/AppIcon.png" width="128" alt="Boundas Gate icon">

> Give AI access to your local workspace without giving it access to your whole computer.

呢句係專案願景。Boundas Gate 嘅長遠定位係 **AI agent 存取本機資源嘅 permission gateway**：用戶選擇資源範圍、容許嘅能力同授權時間，由 backend 同執行環境 enforce。

先做成自己長期用嘅 open-source tool，透過 Public GitHub 同幾位朋友試用。當實際使用證明大家需要個 boundary model，而且相對現成工具有實質優勢，再考慮產品化。

Workspace 係第一種 boundary；之後可延伸到 Git、commands、network、browser、apps 同 session。演進計劃同產品化條件詳見 [Roadmap](ROADMAP.md)。

## 現階段

Boundas Gate 係 macOS 原生 menu bar app，支援兩種模式：每個 folder 獨立 connector，或者一個共用 Read Only connector 管多個已授權 folders。獨立模式沿用 C2C bridge，可選 Cloudflare Quick Tunnel 或 Tailscale 固定地址；共用模式使用獨立 OAuth gateway 同 Tailscale 固定地址。

App 同時喺 Dock 同 menu bar 顯示。關閉管理視窗後仍會運行；撳 Dock icon 可以開返視窗。

目前由 C2C backend 提供工具及檔案限制。Read／Edit／Developer／Custom profiles、完整執行隔離、完整 activity log 同 session 授權仍然係 roadmap 項目，未作為現有安全能力承諾。

## 1.2.0 安裝同升級

支援 Apple Silicon Mac、macOS 14 或以上。DMG／ZIP 安裝步驟見 [安裝說明](INSTALL.md)。本機試用包使用 ad hoc 簽署，未完成 Developer ID 簽署／公證。

已有固定地址嘅連線繼續用原本 Tailscale 裝置，保留 URL 同有效 OAuth；唔會自動切換成另一個內置裝置身份。新安裝嘅共用模式預設內置連線，狀態頁提供登入及公開連線授權連結。獨立 Folder 固定地址模式仍使用原本 Tailscale App。

空白設定測試已驗證 bundle 喺冇 system Node／C2C 路徑嘅環境啟動、建立內置 userspace 核心及登入連結。完整內置 Funnel、另一部實體 Mac、VPN 並用及新帳戶配對仍需實測。自動更新／GitHub Releases 發佈係下一階段。

## 使用

1. 開啟 `dist/Boundas Gate.app`。
2. 喺 menu bar 揀 **Add Folders…** 用 macOS folder picker；按住 **⌘** 可一次選多個資料夾，連續項目可用 **Shift**，再按 **加入所選資料夾**。亦可揀 **Add Workspace by Path…** 直接貼上絕對路徑／`~/` 路徑（包括 worktree）。
3. 對 workspace 按 **連接 ChatGPT…**，跟住引導完成 Mac 連線、ChatGPT 設定同試讀檔案。連線已準備好時，可按 **帶我設定 ChatGPT…**。
4. 可獨立停止連線、Open Logs、Open Folder 或 Remove Workspace；亦可 Start All / Stop All。Remove 會撤銷該 workspace 嘅 OAuth 授權並停止連線。

配對碼有效五分鐘、只可使用一次。過期可喺 workspace 詳細頁或 menu bar 選 **Generate New Pairing Code…**，毋須重啟；新碼會令舊碼失效。App 只喺記憶體暫存目前產生嘅碼，重新開啟後可再產生新碼。

只有明確加入嘅 folder 會交畀 C2C。普通 folder 可讀取、列出及搜尋檔案；Git 功能由現有 C2C CLI 喺 Git repo 提供。Quick Tunnel 每次重新建立可能會換 URL，需要更新 ChatGPT connector。

### 連線檢查同修復

Manager 會定期檢查本機及公開端點，核對 workspace ID、MCP 嘅正常 401／OAuth discovery URL，以及 Bridge 同 Tunnel 公布嘅 URL。程序仍然運行但公開端點失效時，會顯示未就緒；只有通過檢查先可以 Copy URL 或產生配對碼。

1. 選擇正確 workspace。主畫面用簡單文字說明問題同下一步；技術診斷收喺 **連線詳細資料**。
2. 按 **幫我修復連線…**，再按 **開始修復連線**。Manager 會自動啟動或重新建立該 workspace 嘅連線，並重新檢查；新地址未即時回應時會短暫重試。
3. 跟住 **ChatGPT 設定** 引導：一個掣複製正確地址並開啟 ChatGPT Plugins，再按畫面列出嘅欄位建立連線。ChatGPT 要求配對碼時，可喺同一引導產生／複製新碼。
4. 完成設定後，跟住 **試讀檔案** 引導複製測試句子。只有用戶確認 ChatGPT 成功列出檔案後，先顯示測試完成；Mac 檢查通過唔會自行當作 ChatGPT 已連接。

修復失敗時，畫面會提供重新檢查、再試修復同 **複製求助資料**。求助資料包含連線檢查結果，唔包含 pairing code、tokens、原始 CLI output 或本機 folder path；亦唔會自動傳送。需要時可自行交俾幫你設定嘅人。引導進行期間地址改變，會要求重新複製同設定，避免繼續用舊地址。

ChatGPT Plugins 新增連線、Developer mode 同測試步驟按 [OpenAI 官方設定教學](https://developers.openai.com/plugins/deploy/connect-chatgpt) 編寫。每個 workspace 使用自己嘅 port，使用者毋須手動處理。

設定記錄係用戶確認嘅資料。App 無法直接讀取或修改 ChatGPT connector；公開連線檢查亦唔代表完整 OAuth 配對或 ChatGPT tool call 成功。手動另開 cloudflared 唔會同步 Bridge 嘅公開 URL，應由 Manager 重建連線。

1.2.0 發佈包內置 Node.js、已驗證嘅 C2C backend、cloudflared 同 Tailscale userspace 核心。新安裝嘅共用模式毋須另外安裝 Node.js／C2C／Tailscale App；首次仍需要登入自己嘅 Tailscale 帳戶並允許 HTTPS／Funnel。開發模式喺冇 Runtime bundle 時先沿用 `~/codex-with-chatgpt/bin/c2c.js` 同本機 Node.js。設定儲存在 `~/Library/Application Support/Boundas Gate/workspaces.json`；bridge 狀態、PID 同 logs 由 C2C 儲存在 `~/Library/Application Support/codex-with-chatgpt`。App 不會自動加入任何 folder；共用模式只會自動恢復用戶之前已開啟嘅連線。

## Build

```sh
./scripts/build-app.sh
```

Build 輸入需要已驗證 C2C build、Node.js distribution（包含 LICENSE）、cloudflared distribution（包含 LICENSE）及 `Native/Tunnel/go.mod` 指定嘅 Go toolchain；呢啲係開發依賴，唔係試用者安裝要求。可用 `BOUNDAS_C2C_ROOT`、`BOUNDAS_NODE`、`BOUNDAS_GO`、`BOUNDAS_CLOUDFLARED` 同 `BOUNDAS_CLOUDFLARED_LICENSE` 指定輸入。

完成後產生 `dist/Boundas Gate.app` 同 `dist/Boundas-Gate-1.2.0-arm64.zip`；原始依賴授權文件及版本清單包含喺 Runtime。Build 會由 `Resources/AppIcon.png` 產生 macOS `.icns`。再執行 `./scripts/package-release.sh` 產生 DMG 同 SHA256SUMS。發佈包唔包含用戶設定、OAuth、logs 或私人 workspace。

## Tailscale 固定地址（試用）

喺 workspace 撳 **設定固定地址…**。App 會檢查 Tailscale，提供下載／開啟／登入指引；登入並連線後，撳 **啟用固定地址**。首次啟用可能需要喺 Tailscale 網頁允許 HTTPS／Funnel，App 會提供授權連結。完成後用新地址喺 ChatGPT 設定一次 OAuth 連線。

- 個人非商業用途可使用 Tailscale Personal 免費方案，毋須購買網域。需要 MagicDNS、HTTPS 同 Funnel 權限；實際資格及限制以 [Tailscale 官方方案](https://tailscale.com/pricing)及 [Funnel 文件](https://tailscale.com/docs/features/tailscale-funnel)為準。
- 地址格式：`https://<device>.<tailnet>.ts.net/c2c/<workspace-id>/mcp`。同一裝置／tailnet／workspace ID 保持不變時，Stop／Restart 可以沿用地址。重新命名裝置、切換帳戶或搬動 folder 可改變地址。
- 獨立模式每個 workspace 有自己嘅 OAuth 同 ChatGPT connector。需要一個 connector 管多個 folders 時，請用下方「共用 ChatGPT 連線」模式。
- Tailscale backend 狀態、route 設定及公開 MCP 端點會分別檢查；有程序運行唔等於 ChatGPT 已成功使用。
- App 只建立已加入 workspace 嘅入口。現有 443 服務唔屬於本 App 時會拒絕啟用，避免將其他 Serve routes 一併公開。停止只移除本 App 記錄且仍指向原目標嘅 routes，唔使用全域 reset。
- 公開入口經本機 private proxy，只轉送 MCP、OAuth、discovery 同 health；admin routes 拒絕轉送。繼續沿用 C2C OAuth 同 workspace 授權儲存。殘留嘅 background routes 唔會令已停止嘅 private proxy繼續工作。
- 1.2.0 已將 C2C backend 同依賴打包入 App；build 讀取已驗證 backend，唔修改 managed workspace 或原本 C2C repo。

### 驗證範圍

已通過模擬 Tailscale CLI＋真實本機 C2C bridge 嘅測試：多 workspace／單獨停止／固定地址重啟／OAuth 配對／token 保留及 refresh／metadata path discovery／admin 拒絕／設定衝突／失敗清理。

開發機已安裝並登入 Tailscale。共用 gateway 已完成真實 Stop／Start 驗證：固定地址不變，本機同公開 health 正常，MCP 維持 OAuth 保護及原有 discovery 地址。1.1.0 已用現有 既有 MCP Plugin 驗證多個 Folder、配對後新增／取消分享同 gateway 重啟；全程冇重新 OAuth。VPN 切換及休眠恢復仍待實測；此選項暫時屬試用。自動化測試唔會開啟公開 Funnel。

```sh
node --test Tests/Tailscale/provider.test.mjs
BOUNDAS_C2C_ROOT="$HOME/codex-with-chatgpt" node --test Tests/Tailscale/provider.test.mjs
```

## 一個 connector 管多個 Folders（Read Only）

App 預設開啟 **共用 ChatGPT 連線** 頁；開啟、重啟、停止按鈕固定喺頁頂，menu bar 亦可直接操作並顯示共用連線狀態。

1. 勾選已 Add Folder 嘅資料夾。
2. 撳頁頂 **儲存並開啟共用連線**；已儲存清單時按 **開啟共用連線**，等 Mac 端公開地址通過檢查。運行中可按 **儲存變更** 更新 Folder 清單。
3. 複製共用 URL，喺 ChatGPT 新增一個名為 Boundas Gate、使用 OAuth 嘅 connector。
4. 喺 App 產生配對碼，再填入 OAuth 授權頁。配對授權連接呢個 Boundas Gate instance；App 會顯示目前分享嘅 Folders，之後確認分享嘅 Folders 亦可讀取。
5. 複製多 Folder 測試句子，確認 ChatGPT 可以先 `list_workspaces`，再讀取每個已授權 root。成功後先移除唔再用嘅舊 connectors。

同一個 connector 提供七個只讀工具：`list_workspaces`、`workspace_info`、`list_directory`、`read_file`、`search_workspace`（literal search）、`git_status`、`git_diff`，另有選用通行碼嘅 `unlock_workspace`。除列出清單及解鎖外，每個工具都要求 `workspace_id`；唔接受工具呼叫指定新 root。普通 folder 同 Git worktree 都支援。檔案同 Git 讀取沿用 App runtime 嘅 C2C backend，唔提供寫檔、commit、shell、tests 或 build 工具。Git 讀取額外停用 fsmonitor／hooks／custom diff／textconv，同避免 optional index writes。Repo 有 custom clean／smudge／process filters 時，停用 Git 工具，保留一般檔案工具。

### 共用連線斷線後

- 頁頂 **斷線後自動恢復** 預設開啟。App 運行時定期檢查，Mac 喚醒後亦會再檢查；失敗會逐步延長重試間隔，最多兩分鐘。
- 一般斷線按 **修復共用連線**，只恢復 tunnel，保留 gateway、固定地址、OAuth 同 Folder grants。App 重開後亦會恢復之前已開啟嘅連線；手動 **停止**／Stop All 會記住停止狀態。
- 固定地址首次建立後會保存。Tailscale 帳戶／裝置地址唔一致時停止重連並提示，唔會自動換地址。App 唔會自行切換 VPN 或登入其他帳戶。
- 普通斷線／重連、新增／取消分享 Folder 唔需要重建 ChatGPT Plugin 或重新配對。首次連接、授權被撤銷／refresh token 過期時仍需 OAuth 授權。完整 gateway 重啟會令選用 Folder 通行碼嘅暫時解鎖失效，但保留有效 OAuth。
- App 只檢查 Mac 同公開端點，唔會將檢查通過當作 ChatGPT 已完成配對。恢復後可喺原有 chat 再試讀檔案。

Plugin Creator 可以整理 Plugin icon、說明同使用指引；共用地址、OAuth 持久儲存及重連由 Mac App／gateway 處理。由 MCP App 自動產生嘅現有 Plugin 唔支援 Plugin Creator archive update，今次 App 更新唔會建立另一個 Plugin。

### Folder 通行碼（選用，預設關閉）

喺共用連線展開 **Folder 通行碼（選用）**，為個別 Folder 開啟 **要求通行碼**。撳 **產生通行碼** → **複製解鎖句子**，貼入 ChatGPT。首次升級時，按 **更新共用連線** 載入新版；舊 daemon 未支援通行碼時，App 會拒絕開啟保護設定。

- 一次性通行碼五分鐘內有效。`unlock_workspace` 會換取最多 30 分鐘嘅 `access_key`，受 OAuth token 本身到期時間限制。每次讀取都要帶呢個 key；只傳 Folder ID 或對話 ID 唔會授權。
- 開啟保護後，Folder 會喺冇 key 嘅 `list_workspaces` 隱藏。Key 只限該 Folder、同一 OAuth access token 及同一 `openai/session`。缺少對話資料時拒絕解鎖／讀取，唔會改為全域授權。通行碼唔可以存取未分享 Folder，亦唔可以增加 OAuth 操作權限。
- **未開啟通行碼嘅其他 Folders 仍可按 OAuth 權限讀取**。想以通行碼控制全部 Folders，就要逐個開啟。
- **即時鎖定**、重新產生通行碼會撤銷該 Folder 嘅碼及暫時讀取權；共用連線重啟、OAuth token 更新、停用／移除 root 或保護設定改變後亦要重新解鎖。關閉要求通行碼，恢復原有 OAuth 存取。
- 碼、key 只保存 hash 喺 daemon 記憶體；App 只暫存未使用嘅碼，唔寫入設定或 logs。貼入 ChatGPT 嘅碼及 tool 返回嘅 key 可能保留喺對話記錄。撤銷唔會刪除之前已讀取嘅內容。

`openai/session` 按 [OpenAI Docs](https://developers.openai.com/plugins/reference) 用於關聯同一對話，未被官方定義為授權憑證。本功能以 OAuth 同隨機 capability key 作實際憑證，再加對話 metadata 綁定；唔將對話 ID 視為獨立、可驗證嘅身份證明。真實 ChatGPT 嘅 metadata 傳送仍待實測，其他 MCP client 若冇呢個欄位，會拒絕解鎖。

### 共用授權規則

- 共用清單只接受 App 已 Add Folder 嘅來源 ID；預設唔共用任何 folder。
- **1.1.0 起，pairing／OAuth 授權連接呢個 Boundas Gate instance**，包括 App 目前及之後由用戶確認分享嘅 Folders。Token 保存 `bg.instance.<gateway-id>` 同原有操作 scopes，唔再保存 Folder ID 清單。
- Add Folder 只加入 App 清單；必須勾選並儲存分享清單先提供存取。分享新 Folder 後，現有 Plugin 下一次 request 就可以列出及讀取，毋須重新 OAuth／pairing。
- 取消勾選並儲存會即時拒絕該 root；移除 App folder 亦會先撤銷共用存取。重新加入仍要明確確認分享，先會再提供讀取。
- 每個工具同解鎖操作都核對 instance scope、操作 scope、當前分享清單及 App 來源 ID。讀檔沿用 backend canonical path／symlink／secret 限制；非同步讀檔返回前再次核對分享狀態、root epoch 同選用通行碼，撤銷中嘅結果唔會送出。
- Gateway 有獨立嘅 OAuth store 同 runtime。原有獨立 folder connectors 保留；停止獨立 bridge 唔等於撤銷共用 root，兩者喺 UI 分開管理。Stop All 會停止共用 gateway 同獨立 bridges。
- 共用地址沿用 Tailscale transport，同 `/c2c/<gateway-id>/mcp` 固定入口。重啟保留 gateway ID、OAuth store 同 root 授權版本。

### 升級 1.1.0／舊 client 相容

舊 access／refresh token 喺通過原有 AuthStore 驗證及 gateway identity 核對後，原本嘅 `bg.<root-id>.<epoch>` scope 會轉成 instance scope，操作 scopes 保持原狀。未過期嘅舊 Plugin 唔需要重新 Add 或重新配對；refresh rotation 會將新 scope 持久儲存。未知、已撤銷、過期、其他 instance 或從未配對嘅 token 唔會因相容處理取得權限。

舊 client 升級後會讀到 App 所有目前及之後明確分享嘅 Folders，唔再限於最初 pairing 嘅清單。呢個係有意嘅授權行為改變。只停止分享某 Folder 唔會撤銷整個 client；需要停止全部 client 存取時可按 **撤銷全部授權**。

開啟新版 App 後，如服務仍係舊版，按 **套用新版授權** 重啟共用 gateway。固定 URL、client IDs 同 OAuth credential 儲存保持不變。Mac 重啟後要開返 App，先會按原有啟停設定恢復連線；冇新增開機自動啟動功能。OAuth 正常 expiry／refresh／revoke 規則保持不變，唔係永久 token。

檔案安全限制仍依賴 C2C backend；尚未實作 roadmap 入面嘅完整 OS 執行隔離、Edit／Developer profiles 或 activity log。

### 共用 Gateway 驗證

已用真實本機 C2C OAuth／MCP SDK 同暫存 folders 驗證：instance pairing、同一 access／refresh token 讀配對後新增嘅 shared roots、全部六個 Folder／Git 讀取工具動態授權、停用／重新加入、移除來源、舊 token 相容及 refresh 持久儲存、操作 scopes 保持不變、重啟保留 OAuth、未分享 root／路徑／symlink／secret 拒絕、撤銷進行中讀檔同 Git hook／custom diff 拒絕。自動化測試只綁定 localhost，唔會開公開 Funnel。

通行碼測試另外覆蓋：預設關閉及舊設定兼容、全部檔案／Git 工具鎖定、一次性碼、不同 Folder／OAuth token／對話拒絕、缺少 session 拒絕、過期及猜碼限制、即時撤銷進行中讀檔、重啟鎖定、舊 daemon 升級保護。

2026-10-06 已沿用真實 既有 MCP Plugin 完成動態授權驗收：舊連線原本只見較少 Folder，升級後見到目前多個；新增並分享臨時 Folder 後可列出及讀取，取消分享後消失，舊 workspace ID 被拒絕；gateway Stop／Start 後原有連線仍可列出多個 Folder，固定 URL 不變；未加入 Folder 同越界 absolute path 均被拒絕。全程冇重新 OAuth／pairing，測試 Folder 已清除。

今次 live test 透過 App 同一份 workspace store 及共用服務套用新增／取消分享設定，再經真實 Plugin 呼叫驗證。未有執行 App 畫面點擊或實際重啟 Mac；Mac 重啟後仍需開返 App。Folder 通行碼嘅真實對話 metadata 驗收另外追蹤。

```sh
BOUNDAS_C2C_ROOT="$HOME/codex-with-chatgpt" node --test Tests/Gateway/gateway.test.mjs
```

### 1.2.0 安裝包驗收

40 項 App、40 項 Gateway／連線及 7 項 Go race tests 通過。空白設定已驗證內置核心登入連結及重試保留身份。現有共用 Gateway 改用 bundle Node／backend 並重啟後，原有 既有 MCP Plugin 仍可列出多個 Folder 同讀取檔案，固定 URL／OAuth 保留，冇重新 pairing。內置完整 Funnel 同 VPN 並用仍待登入實測。修改檔案及範圍見 [1.2.0 更新紀錄](RELEASE_NOTES.md)。

### Product state / build artifact migration

Production 資料改用 `~/Library/Application Support/Boundas Gate`；App 會先安全遷移舊資料，保留舊資料夾作備份，失敗時停止啟動。New User Test 輸出改到 `.build/apps/Boundas Gate New User Test.app`，資料 profile 保持獨立。詳見 [branding/state migration](docs/branding-state-migration.md)。
