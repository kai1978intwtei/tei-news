# OnTime ‧ 共享行事曆

TEi Composites 公司內部共享行事曆，**1:1 取代 TimeTree** 讓同仁無痛轉換。
生態系第 4 個姊妹系統，與 **PMSYS / ProjFlow / RTM** 互通身份與資料。

- **無痛轉換**：完全沿用 TimeTree 的資訊架構與操作手感——底部 4 分頁、頂部日曆切換、每本日曆的動態/Keep/聊天，零學習成本。
- **乾淨風格**：TimeTree 的清爽卡片式 UI，主色換成品牌橘 `#E8740C`、字體 Inter Tight + Noto Sans TC，與三系統一致。
- **零摩擦進入**：行程通知工具講求方便——不用 Apple/Google、不用 email/密碼，**點名字即可開始**，記住後直接進；從姊妹系統翻頁進來自動帶身份。
- **單檔 PWA**：`index.html` 內含全部畫面與邏輯，可直接放上 GitHub Pages / Vercel。

## 與 TimeTree 對照的功能

| TimeTree | OnTime | 狀態 |
| --- | --- | --- |
| 底部分頁（月曆/Keep/フィード/更多） | 月曆 / Keep / 動態 / 更多 | ✅ |
| 頂部日曆切換（全部/單一） | 日曆切換器 + 顯示開關 | ✅ |
| 月 / 週 / 日檢視 | 月格+當日清單、週、日，可左右滑動 | ✅ |
| 多本共享日曆、顏色 | 公司/部門/私人多日曆，8 色 | ✅ |
| 成員邀請與權限 | owner / editor / viewer | ✅ |
| 行程：整天、重複、多組提醒、地點、URL、備註 | 全部 | ✅ |
| 出席（参加/未定/欠席） | 參加 / 未定 / 不參加 | ✅ |
| フィード（活動 + 聊天） | **訊息**（純聊天）+ 頂部 🔔**通知**（系統活動）拆開，各有未讀數 | ✅ |
| Keep（共享備忘/連結，可釘選） | Keep：備忘 / 連結，可釘選 | ✅ |
| 行程搜尋 | 標題/地點/備註全文搜尋 | ✅ |
| 推播提醒 | 行程前 N 分鐘本機通知（SW） | ✅ |
| 每個行程的留言串 | 行程詳情底下對話串，連動到日曆動態 | ✅ |
| 跨日行程連續色條 | 月格橫跨數天的連續 bar | ✅ |
| 國定假日 / 節日 | 內建台灣假日（月/日顯示，紅字） | ✅ |
| 行程自訂顏色標籤 | 每個行程可選色，不跟日曆色 | ✅ |
| Apple / Google 登入 | **點名字即可開始（零摩擦）** | 🔁 刻意不同 |
| 週起始日設定、通知收件匣、@提及、附件、拖拉改時間 | — | ⏳ 後續補 |

> 你接下來要持續加的功能，照同一套資料層與分頁架構擴充即可。

## 進入（零摩擦，免登入）

- 行程通知工具講求方便：開啟 → **點自己的名字** → 直接進入，記住後下次免再點。
- 身份僅用來標示「誰建立 / 留言」與共享日曆權限，不是密碼關卡。
- 從姊妹系統 SSO 翻頁進來（`?from=projflow&u=&email=`）自動帶身份、跳過選名字。
- 「更多 → 切換使用者」可隨時換身份。

## 兩種資料模式

`index.html` 頂端：

```js
const SUPABASE_URL = '';        // 留空 = 本機原型 (localStorage)
const SUPABASE_ANON_KEY = '';   // 填入 = ☁️ 雲端同步、多人即時
```

填入金鑰前，先到 Supabase SQL Editor 執行 `migrations/2026-06-11-ontime-schema.sql`。

## 試用

瀏覽器開 `ontime/index.html`（或部署網址）→ 點任一名字（如 Kai）即進入。
底部分頁切換；右下 ＋ 新增行程/ Keep；頂部切換器選日曆；🔍 搜尋；「更多」可開推播、安裝、翻頁、切換使用者。

## 上架手機平台

### A. PWA 安裝（立即）
已附 `manifest.webmanifest` + `sw.js` + `icon.svg`。iPhone：Safari 分享 → 加入主畫面；Android：Chrome 選單 → 安裝應用程式。

### B. App Store / Google Play — Capacitor
```bash
npm i @capacitor/core @capacitor/cli @capacitor/ios @capacitor/android
npx cap init OnTime com.teicomposites.ontime --web-dir=ontime
npx cap add ios && npx cap add android
npx cap copy && npx cap open ios       # Xcode → Archive
npx cap copy && npx cap open android   # Android Studio → Bundle
```
- 商店圖示需 PNG：由 `icon.svg` 匯出 1024×1024 給 `@capacitor/assets`。
- 真背景推播：iOS/Android 用 Capacitor Push + FCM/APNs；Web 用 VAPID + Supabase Edge Function（`push_subscriptions` 已備）。

### C. Android TWA
PWA 達標後用 Bubblewrap 包成 TWA 上 Play。

## SSO 契約（與 PROJFLOW_HANDOFF.md 一致，from=ontime）

```
ProjFlow : https://pm-system-mauve.vercel.app/dashboard?from=ontime&u=&email=&name=&enName=&tutorialDone=1
PMSYS    : https://kai1978intwtei.github.io/tei-news/teipmsys/?from=ontime&u=&email=&tutorialDone=1
RTM      : https://rtm-rtm-app-app.vercel.app/index.html?from=ontime&u=&email=&tutorialDone=1
```
> 三系統接收端需把 `ontime` 加入允許的 `from` 來源。

## 檔案

```
ontime/
  index.html              單檔 App（登入 + 月曆/Keep/動態/更多 + 雙模式資料層）
  manifest.webmanifest    PWA manifest
  sw.js                   Service Worker（離線殼 + 提醒/推播）
  icon.svg                App 圖示（上架請匯出 PNG）
migrations/
  2026-06-11-ontime-schema.sql   Supabase 表 + 公司網域認證 + RLS
```
