# Boundas Gate — Roadmap

## 專案定位：GitHub-first，先自用

專案名稱：**Boundas Gate**；建議 Public GitHub repo slug：`boundas-gate`。App 顯示名稱同 build 產物已同步，內部 C2C backend 同既有設定路徑沿用。

> Give AI access to your local workspace without giving it access to your whole computer.

長遠定位：**A permission gateway for AI agents accessing your local machine.**

先做成自己真係長期用嘅 open-source tool，同幾位朋友持續試用；當 boundary model 嘅需求同實質優勢得到驗證，再考慮產品化。

核心互動：用戶揀邊個 project、俾幾多權、容許邊類 action，以及授權幾耐；gateway 強制限制 AI agent 喺授權範圍內操作。

優先次序：**自用可靠性 → 可驗證嘅權限邊界 → 清晰嘅 UI → 工具擴充**。

以下係演進計劃，未設定推出日期；未完成項目唔代表現有 App 已經提供該能力。

### 試用同產品化條件

- [ ] 開發者持續用於日常 project，記錄設定、重連、worktree 切換同配對嘅實際問題。
- [ ] 邀請幾位朋友喺自己部機使用，收集安裝難度、失敗情況同最常用 workflow。
- [ ] 核對大家係咪理解及依賴 boundary model，能否清楚設定同撤銷權限。
- [ ] 用相同工作任務比較現成工具，確認權限模型有實質優勢。
- [ ] 記錄實際超出範圍嘅操作被拒絕、權限到期同撤銷嘅驗證結果。

若主要價值係方便啟動 MCP，繼續維護為 open-source utility。若用戶持續因清楚、可靠嘅 boundary model 而選用，而且自用需求成立，再規劃產品化。現階段以開源工具嘅可靠性同使用回饋推進。

## V1：多 Workspace Manager（現有基礎）

- [x] macOS 原生 menu bar App。
- [x] Boundas Gate 顯示名稱、透明外圍 App icon，同直接引用原圖嘅四角框＋無限符號 menu bar icon。
- [x] 任意 Add Folder，支援普通 folder、Git repo 同 Git worktree。
- [x] 直接輸入／貼上絕對路徑或 `~/` 路徑。
- [x] 每個 workspace 獨立 Start／Restart／Stop bridge 同 tunnel。
- [x] 管理 workspace config，顯示狀態、port、PID 同 MCP URL。
- [x] Copy URL、Open Folder、Open Logs、Open ChatGPT。
- [x] 一次性 pairing code、到期時間、重新產生配對碼。
- [x] 只將用戶明確加入嘅 folder 交畀 C2C。

目前沿用 C2C backend：**每個 workspace 對應獨立 ChatGPT connector**。Manager 尚未提供下列 Read／Edit／Developer／Custom policy engine；實際可用工具同檔案限制由 C2C backend 決定。

### V1.1：Public GitHub 分享版

發佈方向已選定：**Public GitHub repository，GitHub-first**。

- [ ] 整理 repo、README、設定教學、架構說明同授權文件。
- [x] 1.2.0 將已驗證 C2C 0.1.3 build 同完整 runtime dependencies 打包，記錄版本及來源摘要，保留原始授權文件。
- [x] 內置 Node.js／cloudflared／C2C；bundle 缺失時提供重新安裝提示，唔依賴試用者開發環境。
- [ ] 提供乾淨安裝流程，唔依賴開發者本機環境。
- [ ] GitHub Releases 提供 `.app.zip`／DMG、版本資料同安裝指引。
- [x] 試用包標示 Apple Silicon、macOS 14+；其他架構尚未提供。
- [ ] 建立自動 build／release 流程，規劃 Developer ID 簽署同 notarization。
- [ ] 以全新用戶環境驗證 Add Workspace → Start → Pair → MCP 存取。

公開範圍：App source、文件、build script 同發佈套件。workspace config、OAuth tokens、pairing codes、logs、私人 project 同簽署憑證留喺用戶本機。

### 1.2.0 試用包：內置 runtime 同連線核心

- [x] Node.js、C2C、cloudflared 同原始依賴 licenses 包含喺 App。
- [x] 新安裝共用模式預設 tsnet userspace 核心，私人 IPC 同 persistent identity；唔建立 OS VPN interface。
- [x] UI 提供內置帳戶登入同 HTTPS／Funnel 授權；公開入口只接受 MCP／OAuth／health，拒絕 admin routes。
- [x] 舊固定地址預設沿用 external transport，身份／URL 唔一致時拒絕取代；保留 OAuth 同動態分享清單。
- [x] 空白 HOME、冇 system Node／C2C 路徑驗證 CLI、內置核心同登入連結。
- [ ] 完整新帳戶內置 Funnel → ChatGPT pairing → MCP 驗收、另一部實體 Mac 同 VPN 並用測試。
- [ ] 提供可由 UI 明確確認嘅舊裝置 → 內置裝置遷移；目前唔會自動轉換。
- [x] 產生本機 DMG／ZIP、安裝說明及 SHA256SUMS；乾淨 staging 解壓後簽署驗證通過。
- [x] 1.2.0 bundle runtime 重啟現有共用 Gateway 後，原有 Plugin 仍可列出已分享嘅 Folders 同讀取檔案，URL／OAuth 保留。
- [ ] 將 DMG／ZIP 同版本說明發佈到 GitHub Releases。
- [ ] Developer ID 簽署、notarization 同乾淨 Mac 首次開啟驗收。
- [ ] Sparkle 自動更新：固定 GitHub release／appcast、簽署 update、版本通知及保留設定。待確定 repo URL 後接入。

### V1.2：日常使用同連線可靠性

- [ ] 一次安裝後由 UI 完成設定，減少用戶處理 cloudflared、MCP 同 ports 嘅需要。
- [x] 加入試用 Tailscale Funnel 固定地址選項、安裝／登入檢查及授權引導；沿用 C2C OAuth，每個 workspace 獨立入口。
- [ ] 用真實 Tailscale 帳戶及 ChatGPT 驗證固定地址連線；用戶已確認獨立 workspace 嘅固定地址可以連到 ChatGPT；重啟、休眠等情況仍需繼續驗證。
- [ ] 驗證 Stop／Restart 後 endpoint 保持不變；Quick Tunnel 保留作可選模式並標示 URL 會變。
- [x] 共用 gateway 真實 Stop／Start 後固定地址不變，本機同公開 health／OAuth discovery 檢查通過；1.1.0 已沿用現有 Plugin 完成重啟後實際呼叫。
- [x] 共用模式保存固定地址、用戶啟停意向同自動恢復設定；正常重連只恢復 tunnel，保留 OAuth／root grants。
- [x] App 輪詢及 Mac 喚醒後自動恢復已開啟嘅共用連線，重試有退避；手動停止唔會自動再開。
- [x] 固定地址變更時拒絕自動取代，提示原有 Tailscale 帳戶／裝置；測試覆蓋 gateway 重啟後舊 token 同 refresh token、tunnel 重連後通行碼 capability 仍可用。
- [ ] 處理休眠、網絡切換、斷線重連同失敗狀態，避免顯示過期嘅 Running／URL。
- [ ] 清楚顯示 connector 嘅設定、配對及重連狀態。
- [x] 定期檢查本機／公開端點、workspace ID、MCP OAuth discovery URL 同 Bridge／Tunnel URL 一致性。
- [x] UI 提供檢查／重建連線，公開端點失效時唔再以程序 Running 當連線可用。
- [x] 保留 URL 變更記錄，同用戶確認嘅 ChatGPT Server URL 比較並提示更新。
- [x] 非技術用戶修復引導：簡單問題說明、主要操作掣、Mac 自動重連、ChatGPT 欄位教學、配對碼及只讀測試。
- [x] 技術資料預設收起；失敗時提供下一步同可複製嘅求助資料。
- [ ] 喺日常使用同朋友試用中驗證上述行為，再作為穩定版本發佈。

## V2：Workspace 權限同受控檔案編輯

每個 workspace 可以選擇獨立 access profile；新 workspace 預設 **Read（Read Only）**。

| Profile | Files | Git | Commands |
| --- | --- | --- | --- |
| Read（Read Only） | list／read／search | status／diff | 無 |
| Edit（Read & Write） | 上述功能，加 apply patch、create／rename／edit | status／diff | 無 |
| Developer | Edit 功能 | status／diff；寫入操作另行授權 | 已啟用嘅 tests／build／lint profiles |
| Custom | 按工具授權 | 按操作授權 | 按 profile 授權 |

- [ ] UI 顯示 Access、Files、Git、Tests、Build、Shell、Network、Secrets 嘅實際設定。
- [ ] backend 建立 policy engine，逐次驗證 workspace、工具同操作權限。
- [ ] 工具列表反映權限；即使 client 直接呼叫被停用工具，server 亦會拒絕。
- [ ] 權限更新即時生效，已建立嘅 session 同憑證唔可以保留被撤銷嘅能力。
- [ ] 檔案寫入提供變更預覽、原子更新同可追蹤記錄。
- [ ] Git add／commit 獨立開關；push、reset、clean 等操作另設權限及確認。
- [ ] 完善 Git-aware editing：patch 預覽、衝突提示、變更檢視，同已授權 tests／build workflow 嘅銜接。

### Activity log、授權期限同撤銷

- [ ] UI 顯示 AI 幾時讀過、改過、執行過乜，以及容許／拒絕結果同所用權限。
- [ ] 記錄 workspace、client／session、tool、資源、時間同結果；敏感內容處理及保留時間由用戶控制。
- [ ] 權限支援持續授權、指定期限同「今次 session only」。
- [ ] 用戶可隨時 revoke；backend 即時拒絕新操作，撤銷相關 session／credentials，同中止相關執行。
- [ ] 授權期限由 backend 驗證，處理 App 重開、休眠及時間變化，避免到期後保留權限。

未來 Custom profile 示例（未實作）：

```yaml
workspace: NetNavi
access: Custom
files: Edit
git: ReadOnly
commands: [pytest]
network: false
secrets: false
grant:
  scope: session
  durationMinutes: 30
```

呢個 profile 表示今次 session 最多 30 分鐘內可以 edit 指定 workspace 同執行已授權嘅 pytest profile；command、子程序、network 同 secret 限制需通過 V3 隔離驗收先啟用。

### 四個必須由 backend enforce 嘅邊界

| Boundary | 要求 |
| --- | --- |
| Workspace | path 正規化及解析後仍在授權 root；阻止 traversal、symlink 逃逸，同檢查／存取之間嘅競態 |
| Tool | 每個 tool 同 action 都要核對 profile，唔依賴 ChatGPT 記住限制 |
| Command | 限定 executable、argv、cwd、environment、timeout 同資源；subprocess 受相同限制 |
| Secret | 預設封鎖 `.env`、credentials、private keys；檢查 file、search、diff、logs 同 command output 嘅外洩途徑 |

Git worktree 嘅 `.git` 會指向 root 外嘅 metadata。Git 工具需用獨立受控介面處理必要 metadata 存取，清楚限制共享 refs／objects 嘅操作；一般檔案工具唔因此取得其他 workspace 嘅存取權。

## V3：Developer Commands 同執行隔離

**Developer 必須有可驗證嘅執行隔離。** 單靠 cwd、command allowlist 或 UI 顯示「workspace only」，不足以限制 project scripts 同 subprocess。

- [ ] 採用經驗證嘅 OS／容器隔離方案，限制 filesystem、network 同 subprocess。
- [ ] 隔離唔可用或無法驗證時，停用 Developer execution，保留已驗證安全嘅工具。
- [ ] 提供 tests／build／lint profiles；用戶檢視同啟用具體 command。
- [ ] 使用 executable + argv 執行；自由輸入 shell 同 `bash -c` 唔屬於預設 profile。
- [ ] 將 package scripts、build hooks 同測試程式視為可執行程式碼，同樣套用隔離。
- [ ] Network 預設關閉，可獨立啟用並限制目的地；gateway／tunnel 自身連線同 command network 權限分開。
- [ ] Secrets 預設不可存取；需要時只注入明確授權嘅個別 secret，避免繼承整個登入 shell environment。
- [ ] 設定執行時間、輸出大小、程序數量及取消行為；停止時一併處理子程序。
- [ ] 執行前顯示所需權限，執行後保留經敏感資料處理嘅記錄。

驗收需涵蓋：跨 root 讀寫、symlink／競態、shell 逃逸、子程序、Git hooks、network 存取、secret 外洩，同停止後殘留程序。

## V4：Multi-root MCP Gateway

**Read Only 階段已實作。** UI 可勾選已加入嘅 roots、啟動共用 Tailscale 地址、產生配對碼及撤銷權限；一個 connector 使用七個只讀工具，每次呼叫指定 workspace ID。1.1.0 改成 instance OAuth＋動態分享清單，新增 shared root 毋須重新配對。Edit／Developer、完整 activity log 同執行隔離仍未實作。

一個 ChatGPT connector 可以存取多個已授權 workspace：

```text
ChatGPT
   ↓
Boundas Gate
   ├─ Policy engine
   ├─ NetNavi   → Developer
   ├─ HKBench   → Edit
   └─ Live2D    → Read Only
```

- [x] 每次 tool call 明確指定 workspace ID，由 server 核對授權（列出已授權清單除外）。
- [x] Read Only connector／OAuth token 綁定 gateway instance，保留操作 scopes；每次操作讀取當前分享清單。
- [ ] 每個 root 獨立權限、執行環境、logs 同狀態；跨 workspace 操作需另行授權。
- [x] 新加入 root 由用戶勾選並儲存分享後，現有 connector／refresh token 即時可用，毋須重新配對；相容舊 token。
- [x] Read Only root 停用／移除後即時拒絕存取，返回非同步讀檔結果前再次核對；全域 OAuth revoke 可由 UI 執行。
- [x] Read Only 工具核對 root ID、來源 ID、canonical path 同當前分享狀態；撤銷中嘅非同步輸出同舊通行碼唔會因重新分享而復活。
- [x] 選用 Folder 通行碼，預設關閉；五分鐘一次性碼換取最多 30 分鐘 capability，每次呼叫核對 Folder、OAuth token、對話 metadata 及當前保護設定；可即時鎖定。
- [ ] 用真實 ChatGPT 驗證通行碼解鎖、`openai/session` 傳送、跨 chat 拒絕及 OAuth token 更新後重新解鎖。對話 metadata 只作附加綁定，唔作獨立身份憑證。
- [x] 保留 V1 每個 workspace 一個 connector 嘅使用方式。
- [x] 1.1.0 沿用既有 MCP Plugin，舊 client 由較少 roots 更新至多個 roots；新增／停用 test root、讀檔、越界拒絕同固定地址 gateway 重啟均通過，毋須重新 OAuth／pairing。分享設定經 App 同一份 store／共用服務套用；App 點擊、Mac 重啟及通行碼 metadata 未列入今次 live 驗收。

## V5：擴充本機工具

完成並驗證前述權限同執行隔離後，再加入：

- [ ] Browser：獨立授權 browser session、網站同操作。
- [ ] Excel／documents：限定明確選擇嘅文件同讀寫能力。
- [ ] Codex escalation：明確授權 task、workspace、action 同回傳結果。
- [ ] 其他 local tools：採用同一套 policy、撤銷機制同記錄格式。

每個新增 tool 都要先定義資源範圍、權限、隔離方式及驗收條件。Tool 數量唔作為主要進度指標。

### Workspace 之外嘅 boundary

| Boundary | 長遠控制範圍 |
| --- | --- |
| Folder | 明確選擇嘅 root 同讀寫範圍 |
| Git repo | repo／worktree、metadata 同允許嘅 Git 操作 |
| Command | 已授權 executable、argv、執行 profile 同資源 |
| Network | 允許嘅目的地、連線能力同用途 |
| Browser | session、網站同操作 |
| App／document | 明確選擇嘅 app、文件同能力 |
| Time／session | 指定時限、session 範圍及即時撤銷 |

Workspace 係第一種資源邊界；其後按實際需要擴充，每種 boundary 都要有 backend enforcement 同驗收證據。

## 工具成熟度同未來產品化驗收原則

1. 用戶可以清楚睇到每個 workspace 嘅 scope、access 同運行狀態。
2. 權限由 server 同執行環境強制落實，唔靠模型自律。
3. Files、Git、commands、network 同 secrets 嘅權限可以分開設定及撤銷。
4. 任何新工具都唔可以擴大現有 workspace 或 connector 嘅授權。
5. 發佈文件只承諾已實作並驗證嘅安全能力。
6. 連線穩定、設定容易、activity 可追蹤，授權期限同撤銷可驗證。
7. 開發者同試用者持續使用，並能指出 boundary model 相對替代工具嘅具體價值。
