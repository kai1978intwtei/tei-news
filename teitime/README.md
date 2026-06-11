# TEiTime ‧ 共享行事曆

TEi Composites 公司內部共享行事曆，取代 TimeTree。生態系第 4 個姊妹系統，
與 **PMSYS / ProjFlow / RTM** 互通身份（SSO）與資料（Supabase）。

- **乾淨風格**：沿用 TimeTree 的清爽卡片式 UI，主色換成品牌橘 `#E8740C`、字體用 Inter Tight + Noto Sans TC，與三系統一致。
- **單檔 PWA**：`index.html` 內含全部畫面與邏輯，可直接放上 GitHub Pages / Vercel。

## 功能 (v1)

| 功能 | 說明 |
| --- | --- |
| 共享 / 多日曆 | 公司、部門、私人多本日曆，色點區分，眼睛切換顯示 |
| 月 / 週 / 日檢視 | 月格 + 當日 agenda，可左右滑動換月/週/日 |
| 成員邀請與權限 | 每本日曆 owner / editor / viewer 三級權限，邀請同事 |
| 事件留言 | 每個行程底下留言討論，帶 `cross_id` 與三系統訊息中心對齊 |
| 動態消息 | 新增/編輯/留言/邀請即時進 Feed，未讀紅點 |
| 推播提醒 | 行程前 N 分鐘本機通知（Service Worker） |
| 跨系統翻頁 | 同身份免登入翻到 ProjFlow / PMSYS / RTM |

## 兩種資料模式

`index.html` 頂端：

```js
const SUPABASE_URL = '';        // 留空 = 本機原型 (localStorage)
const SUPABASE_ANON_KEY = '';   // 填入 = ☁️ 雲端同步、多人即時
```

- **留空**：localStorage 原型，含種子資料，立即可玩。
- **填入金鑰**：先到 Supabase SQL Editor 執行
  `migrations/2026-06-11-teitime-schema.sql`，再把 `sbSync()` 換成 upsert + realtime 訂閱即可多人同步。

## 試用

直接用瀏覽器開 `teitime/index.html`（或部署後的網址）。
右下 `＋` 新增行程、`📚` 管理日曆與成員、`🔔` 動態、頭像進「我的」（切身份 / 開推播 / 翻頁 / 安裝）。

## SSO 契約（與 PROJFLOW_HANDOFF.md 一致）

進來：`?from=projflow&u=<id>&email=<email>&tutorialDone=1` → 直接認回身份。
出去（翻頁）：

```
https://pm-system-mauve.vercel.app/dashboard?from=teitime&u=<id>&email=<email>&name=<name>&enName=<enName>&tutorialDone=1
https://kai1978intwtei.github.io/tei-news/teipmsys/?from=teitime&u=<id>&email=<email>&tutorialDone=1
https://rtm-rtm-app-app.vercel.app/index.html?from=teitime&u=<id>&email=<email>&tutorialDone=1
```

> 各姊妹系統的接收端需把 `teitime` 加入允許的 `from` 來源。

## 上架手機平台

### A. 立即可用 — PWA 安裝
已附 `manifest.webmanifest` + `sw.js` + `icon.svg`。
- iPhone：Safari 開啟 → 分享 → 「加入主畫面」
- Android：Chrome → 選單 → 「安裝應用程式」（或自動跳安裝橫幅）

### B. 上 App Store / Google Play — Capacitor 包裝
```bash
npm init -y && npm i @capacitor/core @capacitor/cli @capacitor/ios @capacitor/android
npx cap init TEiTime com.teicomposites.teitime --web-dir=teitime
npx cap add ios && npx cap add android
npx cap copy && npx cap open ios      # Xcode → Archive → App Store Connect
npx cap copy && npx cap open android  # Android Studio → Bundle → Play Console
```
- `server.url` 指向部署網址即可讓 App 殼載線上版（內容更新免重新送審）。
- **圖示**：商店需 PNG。用 `icon.svg` 匯出 `1024×1024` PNG，丟給 `@capacitor/assets` 產各尺寸。
- **真推播**（背景/關閉 App 也收得到）：iOS/Android 用 Capacitor Push + FCM/APNs；
  Web 用 VAPID + Supabase Edge Function 對 `push_subscriptions` 發送（schema 已備）。
  目前 `sw.js` 已實作本機提醒與 `push` 事件接收端。

### C. Android TWA（最輕量上 Play）
PWA 達標後用 [Bubblewrap](https://github.com/GoogleChromeLabs/bubblewrap) 把 PWA 包成 TWA 上架。

## 檔案

```
teitime/
  index.html              單檔 App（畫面 + 邏輯 + 雙模式資料層）
  manifest.webmanifest    PWA manifest
  sw.js                   Service Worker（離線殼 + 提醒/推播）
  icon.svg                App 圖示（上架請匯出 PNG）
migrations/
  2026-06-11-teitime-schema.sql   Supabase 表 + RLS
```
