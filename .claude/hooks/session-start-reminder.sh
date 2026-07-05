#!/usr/bin/env bash
# SessionStart hook：每次新 session 開始，注入一段 AGENTS.md 規則摘要進 context，
# 就算 AI 沒有主動讀 CLAUDE.md/AGENTS.md，規則也會被提醒到。
# 限制：這只對 Claude Code 有效（hooks 是 Claude Code 專屬機制），
# 對 Gemini CLI、Copilot 等其他 AI 沒有作用——那些只能靠它們自己讀
# GEMINI.md / .github/copilot-instructions.md 這類檔案。
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AGENTS_FILE="$REPO_ROOT/AGENTS.md"

if [ -f "$AGENTS_FILE" ]; then
  SUMMARY='本 repo 有 AGENTS.md 強制規則（跨 AI 通用），重點：
①未經親自驗證禁止宣告完成；狀態只能用 ✅已完成（已驗證）/⚠️已修改（未驗證）/❌失敗／受阻 三種，並附實際輸出證據。
②驗證需親自執行兩輪：第一輪正向跑通、第二輪主動假設有錯重讀 diff 挑問題。
③接到工作先規劃（最短路徑/token預算/派工前先讓子代理拿到規則），再報告工作計畫（目標/檔案/步驟/驗證方式）才動手。
④省 token：先講結論、不貼大段程式碼、不做沒被要求的事。
詳見 AGENTS.md 全文與 .claude/skills/verify-done/SKILL.md。
本 session 已安裝 Stop hook 會做關鍵字層級的檢查（非語意理解，可被繞過），請確實遵守規則精神，不要只求通過 hook 格式檢查。'
  jq -n --arg ctx "$SUMMARY" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi
exit 0
