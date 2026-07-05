#!/usr/bin/env bash
# Stop hook：檢查「狀態標記」與「禁用模糊措辭」。
# 這是純文字/正則比對，不是語意理解——只能抓「格式對不對、有沒有出現禁用字」，
# 抓不到「內容是不是真的」。AI 仍可能貼上 ✅ 但其實沒驗證；本 hook 無法識破這種說謊，
# 只能保證「格式上沒漏掉該有的東西」。詳見 repo 根目錄 AGENTS.md。
set -euo pipefail

INPUT="$(cat)"

# 避免無限迴圈：這次 Stop 已經被本 hook 擋過一次，就不再擋第二次。
STOP_HOOK_ACTIVE="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -z "$CWD" ] && CWD="$(pwd)"

# 讀不到 transcript 就放行（fail open）：不確定的時候不擋，避免誤傷。
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  exit 0
fi

LAST_TEXT="$(jq -s -r '
  [.[] | select(.type=="assistant" and ((.message.content // []) | map(.type=="text") | any))]
  | last
  | (.message.content // [])
  | map(select(.type=="text") | .text)
  | join("\n")
' "$TRANSCRIPT" 2>/dev/null || true)"

[ -z "$LAST_TEXT" ] && exit 0

# 粗略判斷工作目錄是否有未提交變更（非精準對應「這一輪」的 diff，只能抓當下狀態）
DIRTY="false"
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ]; then
    DIRTY="true"
  fi
fi

# 三種合法狀態標記（符號＋關鍵字同時出現即可，寬鬆比對）
HAS_STATUS="false"
if echo "$LAST_TEXT" | grep -qP '✅.*已驗證|已驗證.*✅'; then HAS_STATUS="true"; fi
if echo "$LAST_TEXT" | grep -qP '⚠️.*未驗證|未驗證.*⚠️'; then HAS_STATUS="true"; fi
if echo "$LAST_TEXT" | grep -qP '❌.*(失敗|受阻)'; then HAS_STATUS="true"; fi

if [ "$DIRTY" = "true" ] && [ "$HAS_STATUS" = "false" ]; then
  jq -n '{
    decision: "block",
    reason: "偵測到工作目錄有未提交的檔案變更，但回覆中找不到三種合法狀態標記之一（✅ 已完成（已驗證）／⚠️ 已修改（未驗證）／❌ 失敗／受阻）。請依 AGENTS.md 補上正確格式的狀態回報與驗證證據後再結束回合。"
  }'
  exit 0
fi

# 禁用模糊措辭（純關鍵字比對，抓不到語意，只能抓這幾個字面詞）。
# 先剔除反引號包住的片段（``` 圍欄或 `行內` 引用），避免「引用禁用詞清單來
# 說明規則」被誤判成「真的拿來搪塞」。這只是機械式排除，仍抓不到語意。
BANNED_PATTERN='大致完成|應該沒問題|基本上好了|差不多了|理論上可以'
TEXT_FOR_BANNED_CHECK="$(echo "$LAST_TEXT" | perl -0777 -pe 's/```.*?```//gs; s/`[^`]*`//g' 2>/dev/null || echo "$LAST_TEXT")"
if echo "$TEXT_FOR_BANNED_CHECK" | grep -qP "$BANNED_PATTERN"; then
  MATCHED="$(echo "$TEXT_FOR_BANNED_CHECK" | grep -oP "$BANNED_PATTERN" | sort -u | paste -sd ' ' -)"
  jq -n --arg m "$MATCHED" '{
    decision: "block",
    reason: ("回覆中出現規則禁止的模糊措辭：" + $m + "。請改用實際驗證結果重新措辭（三種狀態標記＋具體證據），不得用模糊詞蒙混。")
  }'
  exit 0
fi

exit 0
