---
description: 一鍵觸發 website-audit-seo 代理，對指定目標做網站七維體檢
argument-hint: "[index|salesys|all]（預設 all）"
---

使用 `website-audit-seo` 子代理，對目標 **$ARGUMENTS**（未指定則為 `all`）執行網站總體檢。

請涵蓋七大維度並輸出評分卡：

1. 程式 Bug 查驗
2. 網路安全（防禦性）
3. SEO 效率
4. 網路行銷競爭力與精準打擊
5. 台灣競爭者分析與排前三策略
6. 模擬使用者行為檢驗（採購工程師動線、詢價流失點）
7. AEO／GEO／AIO（讓網站被 Google AI Overviews、ChatGPT、Perplexity、Gemini 主動引用）

輸出要求：
- 七維評分卡（每維 1–10 分 + 一句話結論）
- 依優先級（P0 立即／P1 短期／P2 中期）排序的可執行修正清單
- 每項修正附上 `file_path` 與「改哪裡」的具體位置

⚠️ 遵守 `CLAUDE.md` 紅線：`index.html` 是自動產生的，持久化修正要落在 `fetch_news.ps1` 樣板、`vercel.json` 或新增 `robots.txt`／`sitemap.xml`，不要手改 `index.html` 本體。
