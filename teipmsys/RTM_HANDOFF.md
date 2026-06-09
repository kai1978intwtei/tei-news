# RTM 翻頁規格 — 加上跨系統導向 PMSYS / ProjFlow

> 給 RTM (`rtm-rtm-app-app.vercel.app`) 開發者的對接規格單。
> 自成一份、不需參考其它對話。

## 一、要做什麼

RTM 目前缺少跳轉到另外兩個姊妹系統的功能。請在 RTM 頂部工具列**加兩顆翻頁按鈕**：

1. **翻頁去 PMSYS**
2. **翻頁去 ProjFlow**

跳轉時要帶 SSO 身份參數過去，這樣對方收到後不用再登入。

## 二、目標 URL

| 系統 | 完整 URL |
| --- | --- |
| PMSYS    | `https://teisalessys.vercel.app/` |
| ProjFlow | `https://pm-system-mauve.vercel.app/dashboard` |

> ⚠ **必須用完整 URL，不可用相對路徑**——寫 `/pmsys` 或 `/schedule` 會落在 RTM 自己網域變 404。
> 我們之前在 ProjFlow 端踩過這個坑。

## 三、按鈕程式碼範本

```js
function flipToPMSYS() {
  const u = currentUser;  // 當前登入使用者
  const qs = new URLSearchParams({
    from: 'rtm',
    u: u.id,
    email: u.email || '',
    name: u.name || '',
    enName: u.enName || '',
    tutorialDone: hasSeenTutorial(u.id) ? '1' : '0'
  });
  window.location.href =
    `https://teisalessys.vercel.app/?${qs.toString()}`;
}

function flipToProjFlow() {
  const u = currentUser;
  const qs = new URLSearchParams({
    from: 'rtm',
    u: u.id,
    email: u.email || '',
    name: u.name || '',
    enName: u.enName || '',
    tutorialDone: hasSeenTutorial(u.id) ? '1' : '0'
  });
  window.location.href =
    `https://pm-system-mauve.vercel.app/dashboard?${qs.toString()}`;
}
```

**重點**：

- 用 `window.location.href`（**同窗導向**），不要 `window.open`——避免使用者開一堆分頁。
- HTML `<head>` 加 preconnect 預熱兩邊網域，按下按鈕時網路已經就緒：

```html
<link rel="preconnect" href="https://teisalessys.vercel.app" crossorigin>
<link rel="preconnect" href="https://pm-system-mauve.vercel.app" crossorigin>
```

## 四、角色允許清單（重要！三邊必須一致）

三個系統的登入閘必須允許**完全一樣**的 role：

```js
const ALLOWED_ROLES = ['pm', 'pmo', 'admin'];
```

- `pm` / `pmo`：專案管理體系成員
- `admin`：**總經理全權限**，可在 PMSYS / ProjFlow / RTM 之間來去自由，**不要擋下**
- 其它（業務、開發、人資、財務等）→ 拒絕進入，提示「非專案管理體系成員，無權使用本系統」

## 五、收到從 PMSYS / ProjFlow 翻過來時的處理

RTM 載入時要讀 URL 參數，若帶有 `?from=pmsys` 或 `?from=projflow`：

```js
const qp = new URLSearchParams(location.search);
const from = qp.get('from');
if (from === 'pmsys' || from === 'projflow') {
  const user = findUserByIdOrEmail(qp.get('u'), qp.get('email'));
  if (!user || !ALLOWED_ROLES.includes(user.role)) return showAccessDenied();
  if (qp.get('tutorialDone') === '1') markTutorialDone(user.id);
  await signInAs(user);                                // 跳過 OTP 直接登入
  history.replaceState(null, '', location.pathname);   // 清掉網址參數
}
```

## 六、其它要對齊的規格（與 PMSYS / ProjFlow 一致）

| 項目 | 規格 |
| --- | --- |
| **稱呼欄位**         | `enName` 優先；空值則 fallback 中文 `name` |
| **閒置自動登出**     | 60 分鐘無動作自動登出；55 分鐘出 5 分鐘預告 |
| **首次教學引導**     | 強制走一次；透過 SSO `?tutorialDone=1` 旗標互通 |
| **聊天名單**         | 訊息中心須有聊天名單，分組方式：**按部**（DEPTS 中 parent 為空的頂層）+ **按課**（有 parent 的課/中心）；排除本人與 admin |
| **聊天 deep-link**   | SSO URL 加 `&chat=<對象 id>` 應直接開啟與該對象的對話 |
| **跨系統訊息 ID**    | 每則訊息要有 `crossId`，三系統共用同一個 ID 才能讓已讀 / 回覆 / @提及三邊一致 |

## 七、總經理（admin）特例提醒

- admin 在三系統都不擋
- 翻頁時 URL 帶的 `u`/`email` 若是 admin，對方收到後**也要識別並放行**——不可以因為 role 不是 pm/pmo 就擋下來
- admin 可看全部資料；其他 PM 只看自己的專案範圍。這個權限分層三邊都要一致

## 八、SSO URL 契約整理（三邊兩兩雙向）

| 方向 | URL 模板 |
| --- | --- |
| PMSYS → ProjFlow | `https://pm-system-mauve.vercel.app/dashboard?from=pmsys&u=<id>&email=<email>&name=<name>&enName=<enName>&tutorialDone=<0\|1>` |
| PMSYS → RTM      | `https://rtm-rtm-app-app.vercel.app/index.html?from=pmsys&u=<id>&email=<email>&name=<name>&enName=<enName>&tutorialDone=<0\|1>` |
| ProjFlow → PMSYS | `https://teisalessys.vercel.app/?from=projflow&u=<id>&email=<email>&tutorialDone=<0\|1>` |
| ProjFlow → RTM   | `https://rtm-rtm-app-app.vercel.app/index.html?from=projflow&u=<id>&email=<email>&tutorialDone=<0\|1>` |
| RTM → PMSYS      | `https://teisalessys.vercel.app/?from=rtm&u=<id>&email=<email>&tutorialDone=<0\|1>` |
| RTM → ProjFlow   | `https://pm-system-mauve.vercel.app/dashboard?from=rtm&u=<id>&email=<email>&tutorialDone=<0\|1>` |

## 九、正式版（上線時）

- URL 明碼帶身份**只是原型階段**，上線必須改用 **Supabase 共享 session / 簽章 JWT**
- `profiles` 表的 `role` / `enName` / `name` / `crossId` 由 Supabase 統一管理
- 三邊讀同一份 `profiles` 表，原則上不會再有「對齊」問題

---

**收到請回覆**：

1. 已加上兩顆翻頁鈕並測試
2. 角色清單已對齊（含 `admin` 全權限）
3. SSO 收件邏輯已實作
4. 其它規格（英文名、閒置登出、教學、聊天名單）已對齊
