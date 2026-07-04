# 🤖 AGENT-GUIDE — 讓任何 AI 代理都能驅動 sysclean

> 有些 AI 說「做不到」，不是這套系統有問題，而是那個 AI **沒有在你電腦上執行命令的權限**。
> 這份指南把需求講清楚，並提供三種等級的接入方式 —— 連「只會聊天」的 AI 都有辦法參與。

## 為什麼有的 AI 做不到？

掃描和清理必須發生在**被掃描的那台電腦上**。所以 AI 代理需要：

| 能力 | 用途 | 沒有會怎樣 |
|---|---|---|
| 在本機執行 PowerShell | 跑 scan.ps1 / clean.ps1 | 無法自動掃描與清理 |
| 讀本機檔案 | 讀 `reports/latest.json` 分析 | 無法自己看報告 |
| 寫本機檔案 | 產生 `plan.json` | 無法自己交付計畫 |

純雲端網頁對話型 AI（沒有本機代理程式的）三項都沒有 —— 它說做不到是誠實的。
**Claude Code、或任何能在你電腦跑終端命令的 AI 代理**，三項都有，可以跑完整流程。

## 三種接入等級（任選，都安全）

### Level 2 — 全自動（AI 能執行本機命令，例如 Claude Code）
照 `.claude/agents/pc-cleaner.md` 的流程：掃描 → 分析 → 產生 plan.json → 乾跑給你看 → 你同意 → `-Apply` → 重掃驗證。

### Level 1.5 — 橋接執行（AI 不能跑命令，但你要它「可以執行」）★ ProjFlow 用這個

在你電腦啟動**代理橋接器**，它看守一個交件資料夾，遠端 AI 把 plan.json 丟進來就會被執行：

```powershell
# 一次性啟動（常駐看守，每 30 秒檢查）
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\agent-bridge.ps1 -Watch

# 或註冊排程，每 10 分鐘自動處理一輪（建議）
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\agent-bridge.ps1 -RegisterTask

# 想讓雲端 AI 交件？把交件資料夾指到同步資料夾即可：
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\agent-bridge.ps1 -RegisterTask -BridgeDir "C:\Users\你\OneDrive\sysclean-bridge"
```

運作方式：

```
遠端 AI（ProjFlow）                     你的電腦（橋接器）
────────────────────                    ─────────────────────────
1. 讀 outbox\ 裡的掃描報告／結果
2. 產生 plan JSON，寫進 inbox\   ───►   3. 驗證計畫並分級：
                                          ● 零風險（cleanTemp / cleanBrowserCache /
                                            emptyRecycleBin / flushDns）→ 直接執行
                                          ● 深度動作（停自啟／服務／排程／結束程序）
                                            → 乾跑預覽後移到 pending\ 等你核准：
                                              你把檔名改成 xxx.approved.json 丟回 inbox 才跑
4. 讀 outbox\xxx.result.json 得知結果 ◄─  5. 結果（狀態＋完整 log＋還原備份路徑）寫回 outbox\
```

安全底線：不管遠端 AI 寫什麼，實際執行都經過 `clean.ps1` 強制把關
（白名單、允許路徑、`..` 跳脫防護、可逆動作先備份），違規動作一律拒絕。
**交件資料夾（inbox）等於執行權限，只分享給你信任的 AI／團隊。**

### Level 1 — 半自動（AI 只能讀字、回字）
人和 AI 分工，AI 只負責「動腦」：

```
1.（你）跑掃描：
   powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\scan.ps1
2.（你）把 sysclean\reports\latest.json 的內容貼給 AI（或上傳）
3.（AI）依下方「指令模板」分析，輸出 plan.json 的 JSON 內容
4.（你）把 AI 輸出存成 sysclean\plan.json，先乾跑預覽：
   powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\clean.ps1
5.（你）確認沒問題後加 -Apply 執行；後悔可 -Undo 還原
```

就算 AI 亂寫 plan.json 也不會出事：`clean.ps1` 會強制把關（白名單、
允許路徑、動作類型），不合法的動作一律拒絕。

### Level 0 — 不用 AI（純排程）
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\quick-tune.ps1 -RegisterWeekly
```
每週日 12:10 自動掃描＋零風險清理（暫存／各瀏覽器快取／DNS），不動任何設定。

## 給 Level 1 AI 的指令模板（直接複製貼上）

```
你是電腦清理顧問。我會給你一份系統掃描報告 JSON（latest.json）。
請分析後輸出「一份 JSON」（plan.json），格式如下，不要輸出其他文字：

{ "createdAt": "<時間>", "createdBy": "<你的名字>（待使用者核准）",
  "actions": [ { "type": "<動作>", ...參數, "reason": "<理由>" } ] }

允許的動作類型與參數：
- cleanTemp {path}                     清暫存（path 用報告 junk[].path）
- cleanBrowserCache {path}             清瀏覽器快取（path 用報告中 suggestedAction=cleanBrowserCache 的 junk[].path）
- emptyRecycleBin {}                   清資源回收筒
- disableStartupRegistry {key, name}   停用登錄檔開機自啟（來自 startupItems source=registry）
- disableStartupFolder {path}          移出啟動資料夾捷徑（來自 startupItems source=startupFolder）
- disableTask {taskPath, taskName}     停用第三方排程（來自 scheduledTasks）
- setServiceManual {name, stop}        服務改手動（來自 autoServices，thirdParty=true 才可以）
- stopProcess {name}                   結束程序（僅救急降溫用）
- flushDns {}                          清 DNS 快取

分析重點：hints（知識庫建議）、junk（垃圾檔案，先清大的）、
topCpu（發熱元兇）、topMemory（記憶體大戶）、startupItems（state=enabled）、
browserExtensions（逐一確認使用者認得，高權限的要點名；移除請使用者自己在瀏覽器操作，
不要寫進 actions）、installedApps（大型軟體只建議、不寫進 actions）。

安全規則：不認識的東西寧可不動；系統／防毒／網路相關一律不碰；
每個動作都要附白話 reason。
```

## 介面契約（給工程師／AI 看）

- **輸入**：`sysclean/reports/latest.json`（UTF-8）。主要欄位：
  `system`（記憶體/CPU/開機時數）、`disks`、`topCpu`、`topMemory`、
  `startupItems`、`scheduledTasks`、`autoServices`、`junk` + `junkTotalMB`、
  `browserExtensions`、`installedApps`、`largeFiles`、`hints`
- **輸出**：`sysclean/plan.json`（格式見 `plan.sample.json`）
- **執行**：`clean.ps1` 預設乾跑；`-Apply` 執行；`-Undo <備份檔>` 還原
- **強制安全（由 clean.ps1 把關，與 AI 品質無關）**：
  受保護程序／服務白名單、刪檔僅限允許路徑（含 `..` 跳脫防護）、
  Microsoft 排程拒停、可逆動作先備份
