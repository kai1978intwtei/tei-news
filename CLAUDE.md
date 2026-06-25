# CLAUDE.md — TEi-News 專案手冊

> 給 Claude / Claude Code 的專案記憶檔。每次對話開局即讀此檔，**不要再重複向使用者詢問已寫在這裡的事**。
> 語言：與使用者一律用 **繁體中文（zh-TW）** 溝通。使用者為 TEi Composites（台灣碳纖維／複合材料製造商，逾 50 年）。

---

## 1. 五大資產一覽

| 資產 | 路徑 | 性質 | 技術棧 |
|------|------|------|--------|
| 國際新聞站 | `index.html`（~400KB） | 對外、`lang="zh-TW"`、純靜態 | 單檔內嵌 CSS/JS、無框架、無後端 |
| 新聞產生器 | `fetch_news.ps1`（~3,100 行） | 自動化腳本 | PowerShell + DeepL/Google 翻譯 |
| 衝刺艙（業務） | `salesys/`、`teisale-prototype.html`（5,266 行） | 對內、`lang="zh-Hant"` | 前端原型 + Supabase(ProjFlow) 後端 |
| 專案系統 | `teipmsys/` | 對內、規格文件為主 | 對接 ProjFlow |
| CAE 模擬器 | `carbon-plate-cae-simulator.html`（~12,000 行） | 工具 | Three.js + Chart.js、純前端 |
| 稽核儀表板 | `audit-dashboard.html` | 工具 | 純前端 |

---

## 2. 🔴 紅線規則（違反會造成資料遺失或被覆蓋）

1. **禁止手改 `index.html` 本體**。它由 `fetch_news.ps1` + GitHub Actions（`.github/workflows/update-news.yml`，cron `*/10`，**每 10 分鐘**）自動重新產生並 commit。任何手改會在下一次自動更新被覆蓋。
   - 持久化的 SEO／安全修正 → 改在 `fetch_news.ps1` 的 HTML 樣板、`vercel.json`，或新增 `robots.txt` / `sitemap.xml`。
   - 注意：頁面內 `<meta http-equiv="refresh" content="1800">` 是**瀏覽器每 30 分鐘整頁重載**，與「每 10 分鐘產生」是兩回事。
2. **`salesys/` 的 UI 已有定稿原型**（`teisale-prototype.html`）。改動前先對照，並同步更新 `TEISALE-CHANGESET.md`。
3. **`.translate_cache.json`（5.6MB）勿手動編輯或整檔讀取**（會吃光 context）。只看大小／結構。詳見 §5 待辦。
4. 只做合法、白帽、防禦性的安全工作；不協助攻擊對手或負面 SEO。

---

## 3. 自訂 Claude 資產

- **子代理** `website-audit-seo`（`.claude/agents/website-audit-seo.md`）：網站七維體檢（Bug／資安／SEO／行銷／競品／使用者模擬／AEO-GEO-AIO）。
- **子代理** `projflow-backend`（`.claude/agents/projflow-backend.md`）：ProjFlow 後端 schema / RLS / 權限矩陣審查。
- **指令** `/audit`（`.claude/commands/audit.md`）：一鍵觸發 `website-audit-seo` 體檢。

---

## 4. ProjFlow 後端速查（衝刺艙）

- 後端為 Supabase。權限以 `profiles.tier` enum 分級：
  `staff`／`supervisor`／`manager`／`exec`／`assistant`（業助）／`shipping`（船務）。
- 核心資料表：`teisale.assistant_task`、`teisale.shipping_item`、`teisale.contact`，皆有 RLS。
- 完整 DDL／RLS／權限矩陣見 `TEISALE-CHANGESET.md`、`salesys/SYNC_PROJFLOW.md`、`salesys/migrations/`。
- 前端 `personas[].id` 目前多為 placeholder UUID，真名上線時需同步替換（見 CHANGESET §2.2）。

---

## 5. 已知技術債與待辦（依 CP 值排序）

- [ ] **拆配置檔**：把 `fetch_news.ps1` 的 RSS 來源（L87–556）、關鍵字表（L109–160）、翻譯邏輯（L644–760）抽成 `sources.json` / `keywords.json` / `translate.ps1`。
- [x] **快取不入 git**：`.translate_cache.json` 已列入 `.gitignore` 並從索引移除，改由 workflow 的 `actions/cache@v4` 持久化（run_id 為 key、`translate-cache-` 為 restore 前綴）。
- [x] **結構化 commit 訊息**：自動更新訊息已改為 `auto-update <時間> [快取 N 條, index.html NKB]`（見 workflow「Compute commit stats」步驟）。
- [ ] **拆巨型 HTML**：大型單檔的內嵌 CSS/JS 拆成 `css/`、`js/modules/`，降低每次編輯 context。
- [ ] **無測試／lint／建置**：尚無 package.json、ESLint、單元測試。

---

## 6. 部署

- 平台：**Vercel**（`vercel.json`）。`.vercelignore` 已排除 `.translate_cache.json`、`fetch_news.ps1` 等。
- 無建置步驟，直接服務靜態檔。
