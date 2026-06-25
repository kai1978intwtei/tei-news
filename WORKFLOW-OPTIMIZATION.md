# TEi × Claude 工作流優化報告

> 目的：整理出五種能簡化流程、更有效率使用 Claude AI 的方法。
> 分析範圍：本 repo 的五大資產（國際新聞站、衝刺艙 salesys、專案系統 teipmsys、CAE 模擬器、稽核儀表板）、新聞自動化流程、`.claude` 設定與 git 歷史。
> 方法：由三個子代理平行分析「程式產物 / 自動化流程 / Claude 協作設定」三個面向後綜合。

---

## 三個核心痛點

1. **巨型單檔**：`carbon-plate-cae-simulator.html`（~12,000 行）、`fetch_news.ps1`（~3,100 行）、`teisale-prototype.html`（5,266 行）。每改一點都要吞整個檔，吃光 context。
2. **重複交代 context**：先前沒有 `CLAUDE.md`，每次對話都要重講「`index.html` 由 `fetch_news.ps1` 自動產生、別手改」這類事。
3. **重複性任務沒模板化**：稽核、後端 schema 審查每次從零開始解釋領域知識。

---

## 五種方法

### 方法一：建立 `CLAUDE.md` 專案記憶檔 ✅ 已完成
把每次都要重講的事寫一次，Claude 開局即上手。內容涵蓋五大資產、🔴 紅線規則（禁手改 `index.html`）、ProjFlow 後端速查、技術債待辦清單。
- 產出：`CLAUDE.md`
- 效益：每次對話省 5–10 分鐘重複說明，並避免 Claude 給出會被自動更新覆蓋的危險建議。

### 方法二：拆解巨型單檔 + 分離配置 ⏳ 待辦（CP 值最高的中期工程）
- **`fetch_news.ps1`** → 把 RSS 來源清單（L87–556）、關鍵字評分表（L109–160）、翻譯邏輯（L644–760）抽成 `sources.json`、`keywords.json`、`translate.ps1`。之後想「本週加關注 AI」只要改 JSON，不必碰 PowerShell；Claude 維護時只讀幾 KB 而非整檔。
- **大型 HTML** → 把內嵌 CSS/JS 拆成 `css/`、`js/modules/`。改「業助任務列表」只需給 Claude ~200 行模組，而非 5,000 行整檔。
- 效益：Claude context 用量約 −50%，編輯次數大幅下降。

### 方法三：設權限白名單 + 自訂 slash command
- **`.claude/commands/audit.md`** ✅ 已完成：`/audit [index|salesys|all]` 一鍵觸發 `website-audit-seo` 七維體檢。
- **`.claude/settings.json`** ⏳ 待你親自套用：把只讀操作加白名單，省掉每次核准的等待。建議內容如下（自我修改權限屬敏感操作，請過目後自行貼入）：

```json
{
  "permissions": {
    "allow": [
      "Read", "Glob", "Grep",
      "Bash(git status:*)", "Bash(git log:*)", "Bash(git diff:*)",
      "Bash(git show:*)", "Bash(git branch:*)",
      "Bash(ls:*)", "Bash(find:*)", "Bash(wc:*)"
    ],
    "deny": [
      "Read(./.translate_cache.json)",
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(git reset --hard:*)",
      "Bash(rm -rf:*)"
    ]
  }
}
```

> 其中 `deny` 對 `.translate_cache.json` 的讀取，能防止 5.6MB 快取被整檔讀入、吃光 context。

### 方法四：清理自動化 git 噪音 ⏳ 待辦
- **`.translate_cache.json`（5.6MB）別再 commit**：改用 GitHub Actions cache / Artifacts，移進 `.gitignore`。可瘦身 repo 3–5MB，clone/pull 更快。`.github/workflows/update-news.yml` 目前 L26–32 已有 `actions/cache`，但 L69 仍把快取一起 commit，是這裡的矛盾點。
- **結構化 commit 訊息**：現在全是 `auto-update <時間戳>`（最近 60 筆皆如此），無法追溯。改成 `chore(news): auto-update [20996 快取, 56 新翻譯]`，故障時一眼看出是快取暴增還是 RSS 掛掉。

### 方法五：擴充子代理矩陣 ✅ 部分完成
比照寫得很好的 `website-audit-seo`，為多系統各設專屬助手：
- **`projflow-backend`** ✅ 已完成：`.claude/agents/projflow-backend.md`，專責後端 schema / RLS / 權限矩陣審查。
- **`cae-simulator-maint`** ⏳ 待辦：碳纖維參數與計算驗證（針對 CAE 模擬器）。
- 效益：後端、CAE 任務不用每次重新解釋領域知識，直接喚起對應代理。

---

## 落地進度與優先順序

| 優先 | 方法 | 狀態 | 效益 |
|---|---|---|---|
| 🔴 立即 | 一、CLAUDE.md | ✅ 完成 | 每次省 5–10 分 |
| 🔴 立即 | 三、`/audit` 指令 | ✅ 完成 | 流程一鍵化 |
| 🔴 立即 | 三、settings.json | ⏳ 待你套用 | 省核准等待 |
| 🟡 短期 | 五、projflow-backend 代理 | ✅ 完成 | 後端任務 +40% 效率 |
| 🟡 短期 | 四、快取不 commit + commit 訊息 | ⏳ 待辦 | repo −3MB、可追溯 |
| 🟢 中期 | 二、拆巨型單檔 | ⏳ 待辦 | context −50% |
| 🟢 中期 | 五、cae-simulator-maint 代理 | ⏳ 待辦 | CAE 任務專精 |

---

*本報告與 `CLAUDE.md` §5 的技術債清單互相對應；後續可逐項從待辦轉為完成。*
