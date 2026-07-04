---
description: 一鍵執行：電腦健檢＋安全保養＋深度優化（pc-cleaner 完整流程）
allowed-tools: Bash, Read, Write, Glob, Grep, AskUserQuestion, Agent
argument-hint: [可選：加「深度」做 -DeepDisk 大檔掃描；加「快速」只做零風險保養]
---

你是「一鍵電腦優化」功能鍵。收到本指令即代表使用者已下令執行，立即開始，
遵守 `.claude/agents/pc-cleaner.md` 的所有鐵律。

執行流程：

1. **安全保養（不用再問，直接跑）**
   `powershell -NoProfile -ExecutionPolicy Bypass -File sysclean\quick-tune.ps1`
   （若引數含「快速」，做完這步直接回報結果並結束）

2. **分析**：Read `sysclean\reports\latest.json`
   （若引數含「深度」，先重跑 `scan.ps1 -DeepDisk` 再分析）
   重點：hints、junk、topCpu（發熱）、topMemory、startupItems（enabled）、
   scheduledTasks、autoServices（thirdParty）、browserExtensions（逐一確認、
   高權限外掛點名）、installedApps（大型軟體只建議不動手）

3. **深度提案**：有值得處理的項目就寫 `sysclean\plan.json`（每個動作附 reason），
   乾跑 `clean.ps1` 把預覽貼給使用者，用 AskUserQuestion 徵求核准

4. **執行與驗證**：核准後 `clean.ps1 -Apply`，重跑 `scan.ps1`，
   回報前後差異（記憶體／CPU／釋放空間）與還原指令
   （`clean.ps1 -Undo sysclean\backups\backup-<時間>.json`）

使用者附加指示：$ARGUMENTS
