# ProjFlow 對接規格 — 與 PMSYS 互通 SSO 與資料對齊

> 給 ProjFlow (`pm-system-mauve.vercel.app`) 開發者的對接規格單。
> 自成一份、不需參考其它對話。

## 一、急修 bug：ProjFlow 回跳 PMSYS 出現 404

**現象**：在 ProjFlow 點「翻回 PMSYS」之後，瀏覽器落到

```
https://pm-system-mauve.vercel.app/pmsys?from=projflow
```

→ Vercel 404。

**原因**：跳轉 URL 寫成**相對路徑**（推測類似 `/pmsys?from=projflow`），結果落在 ProjFlow 自己的網域底下，當然找不到。

**修法**：必須用 PMSYS 的**完整 URL**，不能用相對路徑。

```js
// ❌ 錯：相對路徑 → 落在 ProjFlow 自己的網域 → 404
window.location.href = `/pmsys?from=projflow&u=${u.id}`;

// ✅ 對：完整 URL
const PMSYS_URL = 'https://teisalessys.vercel.app/';
window.location.href =
  `${PMSYS_URL}?from=projflow`
  + `&u=${encodeURIComponent(u.id)}`
  + `&email=${encodeURIComponent(u.email)}`
  + `&tutorialDone=${u.tutorialDone ? 1 : 0}`;
```

## 二、PMSYS 公開 URL（已部署）

```
https://teisalessys.vercel.app/
```

> ⚠ 不可寫成相對路徑 `/pmsys?...`，會落在 ProjFlow 自己網域變 404。

## 三、SSO URL 契約（雙向）

### PMSYS → ProjFlow（PMSYS 端已實作，僅供確認）

```
https://pm-system-mauve.vercel.app/dashboard?from=pmsys
  &u=<id>
  &email=<email>
  &name=<name>
  &enName=<enName>
  &tutorialDone=<0|1>
```

### ProjFlow → PMSYS（本次要實作）

```
https://teisalessys.vercel.app/?from=projflow
  &u=<id>
  &email=<email>
  &tutorialDone=<0|1>
```

PMSYS 端 onload 已可處理：讀 `?from=projflow` → 用 `u` 或 `email` 直接認回身份、跳過 OTP；`?tutorialDone=1` 會把該使用者的教學完成狀態記到 localStorage。

ProjFlow 端對應要做的相反動作：

```js
const qp = new URLSearchParams(location.search);
if (qp.get('from') === 'pmsys') {
  const user = await findUserByIdOrEmail(qp.get('u'), qp.get('email'));
  if (!user || !ALLOWED_ROLES.includes(user.role)) return showAccessDenied();
  if (qp.get('tutorialDone') === '1') markTutorialDone(user.id);
  await signInAs(user);                                // 跳過 OTP
  history.replaceState(null, '', location.pathname);   // 清掉網址參數
}
```

## 四、ProjFlow 必須與 PMSYS 對齊的規格

### 4.1 PM 角色允許清單

```js
const ALLOWED_ROLES = ['pm', 'pmo', 'admin'];
```

- `pm` / `pmo`：專案管理體系成員
- `admin`：**總經理全權限**，可在 PMSYS / ProjFlow / RTM 之間來去自由，**不要擋下**
- 其它（業務 / 開發 / 人資 / 財務 / 採購 / 行政 等）→ 拒絕進入，提示「非專案管理體系成員，無權使用本系統」

### 4.2 英文名稱呼欄位 `en_name`

- `profiles` 表新增 `en_name`（字串，可空）
- 渲染稱呼時：`en_name` 優先；空值則 fallback 中文 `name`
- 範例：王耀裕 `en_name = 'Brad Wang'`，UI 顯示「早安，Brad Wang」

### 4.3 閒置 60 分鐘自動登出

- 監聽 `mousemove / keydown / click / scroll / touchstart`，每次活動重置 timer
- **55 分鐘** → 跳 5 分鐘預告 toast（不擋操作）
- **60 分鐘** → 自動 `signOut()`，下次進入需重新登入

### 4.4 首次登入教學引導

- 新使用者第一次登入**強制**走完教學（**首次不可關閉**；之後可在 help 入口重看）
- 完成後寫 `localStorage`：`projflow.tutorial.done.<userId> = '1'`
- 若 SSO 帶入 `?tutorialDone=1` → 該使用者直接標為已完成、不再彈引導
- 教學流程須含至少 6 步：歡迎 → 工作檯 → 跨系統資料來源 → 行事曆 / 報告 → 翻書頁到 PMSYS → 「同步更新到 PMSYS」按鈕

### 4.5 「同步更新到 PMSYS」按鈕（admin 限定）

- ProjFlow 也須提供一顆**「同步更新到 PMSYS」**按鈕
- **只有 admin（總經理）角色看得到**——PM 視角隱藏，避免技術規格干擾日常工作流程
- 點開列出 ProjFlow 本側設定變更，並提供「在 PMSYS 中開啟並帶提示」按鈕（呼叫第三節的回跳 URL）

### 4.6 訊息中心 · 聊天名單

兩種分組必須與 PMSYS 一致：

- **按部**：`DEPTS` 中 `parent` 為空的頂層部（如 `dev` / `sales` / `exec` ...），列出該部及其所有後代課的成員
- **按課**：`DEPTS` 中有 `parent` 的課/中心（如 `spe` / `pmo` / `pur` / `hr` / `fin` / `adm` ...）

排除目前使用者本人與 `role === 'admin'` 的帳號。
名單來源以 ProjFlow `profiles` 表為唯一真實來源。

### 4.7 聊天 deep-link（訊息對映關鍵）

在 SSO URL 上額外加 `&chat=<對象 user id>`：

```
<PMSYS_URL>?from=projflow&u=<my-id>&email=<my-email>&chat=<other-user-id>
```

ProjFlow 收到 `?chat=...` 後須直接開啟與該對象的對話視窗——這樣 PMSYS 聊天名單裡的對象才能對上 ProjFlow 同一條訊息串。

### 4.8 跨系統訊息 ID

每則訊息應有 `crossId`（跨系統穩定 ID），三系統共用同一個 ID 才能確保**已讀狀態 / 回覆 / @提及**在 PMSYS / ProjFlow / RTM 三邊一致。

## 五、總經理（admin）特例提醒

- admin 在三系統都不擋
- 翻頁時 URL 帶的 `u` / `email` 若是 admin，對方收到後**也要識別並放行**——不可以因為 role 不是 pm/pmo 就擋下來
- admin 可看全部資料；其他 PM 只看自己的專案範圍。這個權限分層三邊都要一致

## 六、SSO URL 契約整理（三邊兩兩雙向）

| 方向 | URL 模板 |
| --- | --- |
| PMSYS → ProjFlow | `https://pm-system-mauve.vercel.app/dashboard?from=pmsys&u=<id>&email=<email>&name=<name>&enName=<enName>&tutorialDone=<0\|1>` |
| PMSYS → RTM      | `https://rtm-rtm-app-app.vercel.app/index.html?from=pmsys&u=<id>&email=<email>&name=<name>&enName=<enName>&tutorialDone=<0\|1>` |
| ProjFlow → PMSYS | `https://teisalessys.vercel.app/?from=projflow&u=<id>&email=<email>&tutorialDone=<0\|1>` |
| ProjFlow → RTM   | `https://rtm-rtm-app-app.vercel.app/index.html?from=projflow&u=<id>&email=<email>&tutorialDone=<0\|1>` |
| RTM → PMSYS      | `https://teisalessys.vercel.app/?from=rtm&u=<id>&email=<email>&tutorialDone=<0\|1>` |
| RTM → ProjFlow   | `https://pm-system-mauve.vercel.app/dashboard?from=rtm&u=<id>&email=<email>&tutorialDone=<0\|1>` |

## 七、正式版（上線時）

- URL 明碼帶身份**只是原型階段**，上線必須改用 **Supabase 共享 session / 簽章 JWT**
- `profiles` 表的 `role` / `en_name` / `name` / `crossId` 由 Supabase 統一管理
- 三邊讀同一份 `profiles` 表，原則上不會再有「對齊」問題

---

**收到請回覆**：

1. 已修好 ProjFlow → PMSYS 回跳的完整 URL 寫法（沒有 404）
2. 角色清單已對齊（含 `admin` 全權限）
3. 其它規格（英文名、閒置登出、教學、同步按鈕 admin 限定、聊天名單分組、deep-link、crossId）已對齊
