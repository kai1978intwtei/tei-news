# 🧹 sysclean — 個人電腦系統健檢與清理工具組（AI Agent 協作版）

一套「**掃描（唯讀）→ AI 分析 → 出計畫 → 你核准 → 執行（可還原）**」的 Windows 系統保養系統。
專門對付：吃記憶體的背景軟體、讓電腦發熱的 CPU 元兇、藏在各處的垃圾檔案、
非必要的開機自啟與排程任務、暫時用不到的大型軟體。

## 最快用法：對 AI Agent 下一句話

在這個資料夾開 Claude Code，直接說：

> **幫我健檢電腦並優化**

`pc-cleaner` 代理（`.claude/agents/pc-cleaner.md`）就會自動：
掃描 → 讀報告 → 用白話告訴你哪裡有問題 → 寫好清理計畫 → 給你確認 → 執行 → 重掃驗證 → 告訴你怎麼還原。

## 手動用法

```powershell
# 1. 健檢（唯讀，隨時可跑；-OpenReport 直接打開 HTML 報告；硬碟吃緊加 -DeepDisk）
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\scan.ps1 -OpenReport

# 2. 一鍵安全保養（只做零風險：清暫存快取＋DNS，不動任何軟體設定）
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\quick-tune.ps1

# 3. 註冊每週日 12:10 自動保養（要移除：-Unregister）
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\quick-tune.ps1 -RegisterWeekly

# 4. 深度清理：AI Agent（或你自己）寫好 plan.json 後
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\clean.ps1          # 乾跑預覽
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\clean.ps1 -Apply   # 實際執行

# 5. 後悔了？一鍵還原（備份檔路徑在執行完會顯示）
powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\clean.ps1 -Undo sysclean\backups\backup-XXXX.json
```

> 清系統暫存（Windows\Temp、Windows Update 快取）與改服務需要「以系統管理員身分執行」。

## 檔案說明

| 檔案 | 角色 |
|---|---|
| `scan.ps1` | 掃描器：唯讀健檢，輸出 `reports/latest.json`（給 AI）與 `reports/latest.html`（給人） |
| `clean.ps1` | 執行器：只照 `plan.json` 做、預設乾跑、白名單保護、動作前備份、`-Undo` 還原 |
| `quick-tune.ps1` | 一鍵安全保養：掃描＋自動清零風險暫存快取，可註冊每週排程 |
| `config.json` | 安全設定：受保護程序／服務白名單、常見吃資源軟體知識庫、允許清理路徑 |
| `plan.sample.json` | 清理計畫格式範例（AI Agent 產生 `plan.json` 時照這個格式） |
| `report-template.html` | HTML 報告模板 |
| `reports/` `backups/` `logs/` | 掃描報告／還原備份／執行紀錄（自動建立，不進 git） |

## 掃描涵蓋範圍

1. **系統總覽**：記憶體使用率、CPU 即時取樣（找發熱元兇）、各磁碟剩餘空間、開機天數
2. **程序排行**：CPU 前 N 名（取樣期間）＋記憶體前 N 名（同名程序合併，chrome 全家桶看總量）
3. **開機自啟**：登錄檔 Run（HKLM/HKCU/WOW6432Node）＋啟動資料夾，含「已停用」狀態判讀
4. **排程任務**：所有非 Microsoft 排程（很多軟體的更新器藏在這）
5. **自動服務**：開機自動啟動的服務，自動標記第三方
6. **垃圾檔案**：使用者/系統暫存、Windows Update 下載快取、
   當機傾印（CrashDumps/Minidump/MEMORY.DMP）、著色器快取、資源回收筒、Windows.old
7. **瀏覽器深掃（藏在網頁裡的都抓出來）**：
   - Chrome / Edge / Brave / Vivaldi / Opera / Firefox，**所有使用者設定檔**（不只 Default）
   - 快取、Code Cache、GPUCache、媒體快取、**Service Worker 離線儲存**（網站藏資料的地方）
   - **擴充功能盤點**：列出每個瀏覽器裝了哪些外掛（名稱/版本/大小/權限），
     高風險權限（<all_urls>、webRequest、debugger…）自動標紅 —— 挖礦、廣告外掛最常躲這裡
8. **已安裝軟體**：依大小排序前 40 名（找暫時用不到的大型軟體，解除安裝一律人工執行）
9. **大檔案深掃**（`-DeepDisk` 選配）：使用者資料夾 >200MB 檔案前 25 名

## 安全設計

- `scan.ps1` **完全唯讀**，跑一百次也不會動到系統。
- `clean.ps1` 只認 `plan.json`，**預設乾跑**，加 `-Apply` 才動手。
- **白名單底線**：`config.json` 的受保護程序／服務（Defender、網路、音效、輸入法、核心系統）
  即使寫進 plan.json 也會被拒絕執行。
- **刪檔範圍鎖死**：只允許 `allowedCleanPaths` 列出的暫存／快取資料夾，其他路徑一律拒絕。
- **瀏覽器只清快取**：`cleanBrowserCache` 只清 `browserCacheSubdirs` 列出的快取子目錄，
  書籤、密碼、歷史、Cookie、擴充功能本體絕對不碰；可疑擴充功能只「列出來給你看」，
  移除一律由你自己在瀏覽器的擴充功能頁面操作（直接刪資料夾會弄壞設定檔）。
- **凡可逆皆備份**：停用自啟（備份登錄值）、啟動捷徑（搬到 backups/ 而非刪除）、
  排程任務（可重新啟用）、服務啟動模式（記錄原值），全部可 `-Undo` 一鍵還原。
- **解除安裝不自動化**：大型軟體只列清單，由你自己在「設定 → 應用程式」處理。
