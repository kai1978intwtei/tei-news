# 交接指令書：把 kai-bridge 手機遙控接上電腦清潔系統

> 給接手的 session：這份是完整規格＋任務清單。照著做就能讓使用者用手機開
> `kai-bridge.vercel.app` 遙控家裡電腦執行清潔。電腦端程式（cloud-agent.ps1）
> 已寫好並在 `kai1978intwtei/tei-news` 的 `sysclean/` 裡，**你只需要完成
> kai-bridge 後端的兩個 API 端點**，並確認契約一致。

---

## 一、背景（已完成的部分）

使用者電腦上已裝好一套 `sysclean` 清潔系統（在 `kai1978intwtei/tei-news` repo 的
`sysclean/` 資料夾，會同步到 `C:\Users\user\tei-tools\sysclean`）。它有四個遙控指令：

| 指令 | 動作 | 風險 |
|---|---|---|
| `保養` | 清暫存＋全瀏覽器快取＋DNS | 零風險 |
| `健檢` | 系統健檢掃描，產生報告 | 唯讀 |
| `深度預覽` | 產生清理計畫並乾跑（不執行） | 唯讀 |
| `深度清理` | 執行深度清理 | 全部可還原 |

電腦端輪詢器 `sysclean/cloud-agent.ps1` 已寫好：它每 15 秒去 kai-bridge 後端
拿指令、在本機執行、把結果回傳。**它需要 kai-bridge 提供下面兩個端點。**

---

## 二、目標架構（雲端信箱模式）

雲端網頁碰不到本機，所以用 kai-bridge 後端當「信箱」，電腦端輪詢：

```
手機開 kai-bridge 網頁 → 按「保養」→ POST /api/enqueue（存入佇列）
                                            ↓
電腦 cloud-agent 每 15 秒 → GET /api/next（取一筆）→ 本機執行清潔
                                            ↓
                          → POST /api/result（回傳結果）→ 網頁輪詢 /api/status 顯示
```

---

## 三、給 kai-bridge 的任務（後端要做的事）

用 kai-bridge 現有後端（Vercel KV / Upstash Redis / 任何 DB）實作一個
**指令佇列 + 結果表**，並開下面端點。**認證**：用一個共享密鑰 `token`
（存在 Vercel 環境變數，例如 `BRIDGE_TOKEN`），每個端點都驗證。

### 端點 1：手機下指令（網頁前端呼叫）
```
POST /api/enqueue
body: { "command": "保養|健檢|深度預覽|深度清理", "token": "<BRIDGE_TOKEN>" }
行為: 產生唯一 id，存入佇列 { id, command, status:"pending", createdAt }
回傳: { "id": "<唯一碼>" }
```

### 端點 2：電腦取指令（cloud-agent 呼叫）★契約固定
```
GET /api/next?token=<BRIDGE_TOKEN>
行為: 取出最舊一筆 status=pending，標記為 status=taken
回傳(有): { "id": "<唯一碼>", "command": "保養" }
回傳(無): { "id": null }        （或 HTTP 204）
```

### 端點 3：電腦回傳結果（cloud-agent 呼叫）★契約固定
```
POST /api/result
body: { "id":"<同上>", "token":"<BRIDGE_TOKEN>", "status":"done|error",
        "title":"一鍵保養（零風險清理）", "log":"<執行輸出全文>" }
行為: 用 id 更新該筆為 status=done、存 title/log/finishedAt
回傳: { "ok": true }
```

### 端點 4：手機看結果（網頁前端輪詢）
```
GET /api/status?id=<唯一碼>&token=<BRIDGE_TOKEN>
回傳: { "status":"pending|taken|done|error", "title":"...", "log":"..." }
```

> 端點 2、3 的欄位名稱（`id`／`command`／`status`／`title`／`log`／`token`）是
> 電腦端 cloud-agent 寫死的契約，**請勿更名**。1、4 你可自由設計，只要前端配合。
> cloud-agent 也會送 `X-Bridge-Token` 標頭，後端驗 query 或標頭皆可。

### 前端（網頁按鈕）
四顆按鈕 `保養／健檢／深度預覽／深度清理` → 各自 POST /api/enqueue →
拿到 id → 每 3 秒輪詢 /api/status → 顯示 title 與 log。深度清理建議加二次確認。

---

## 四、電腦端怎麼啟用（使用者只需三行，已寫好）

```powershell
cd "$env:USERPROFILE\tei-tools\sysclean"
# 1) 設定 kai-bridge 網址與密鑰（token 要跟 Vercel 的 BRIDGE_TOKEN 一致）
.\cloud-agent.ps1 -Setup -BaseUrl https://kai-bridge.vercel.app -Token <BRIDGE_TOKEN>
# 2) 測試連線
.\cloud-agent.ps1 -TestOnce
# 3) 開機常駐（登入就背景輪詢，電腦沒關就待命）
.\cloud-agent.ps1 -RegisterStartup
```

---

## 五、安全要點

- **一定要有 token**：`/api/next`、`/api/enqueue`、`/api/result` 全部驗 `BRIDGE_TOKEN`，
  否則任何人都能對這台電腦下清潔指令。token 放 Vercel 環境變數，別寫進前端原始碼
  （前端呼叫 enqueue 時可改為由使用者登入後的 session 帶，或設一個只允許 enqueue 的次級 token）。
- 電腦端 `clean.ps1` 的白名單／允許路徑／備份還原照常把關 —— 就算指令被竄改，
  也只會執行受保護範圍內、且可還原的動作。
- `深度清理` 會實際更動系統（但全可還原）；若要更保守，前端可只開放 `保養／健檢／深度預覽`，
  把 `深度清理` 留給電腦本機面板按。

## 六、驗收

1. Vercel 部署後，`GET /api/next?token=<對的>` 回 `{"id":null}`（空佇列）。
2. 電腦跑 `cloud-agent.ps1 -TestOnce` 顯示「連線成功」。
3. 手機網頁按「健檢」→ 30 秒內電腦端 log 出現「收到遙控指令：健檢」→
   網頁 /api/status 顯示健檢結果全文。
4. token 錯誤時所有端點回 401。

（檔案：電腦端 `sysclean/cloud-agent.ps1`；本規格 `sysclean/HANDOFF-kai-bridge.md`）
