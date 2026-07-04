# TEi-Salesys ↔ ProjFlow 同步契約

> 給 ProjFlow (`pm-system-mauve.vercel.app`) 開發者:定義業務系統跟 PM 系統之間,什麼資料要同步、什麼不要、怎麼對口。
> TEi-Salesys 端公開來源:`https://<salesys-domain>/`(原型)+ 本文件。

---

## 一、識別契約 `(dept, email)`

兩系統的使用者對應**不只用 email**,因為:
- email 有可能跨公司重複(同名 mailbox 不同公司)
- email 不能反映「這個人在哪個部門做事」
- 業務部跟 PM 部的權限矩陣完全不同,沒部門無法分流

**契約**:身份識別永遠用 `(dept, email)` 二元組。

### SSO URL 必帶欄位(在現有 `from` `u` `email` `name` `enName` `tutorialDone` 之外新增)

```
https://pm-system-mauve.vercel.app/dashboard?from=salesys
  &u=<id>
  &email=<email>
  &name=<name>
  &enName=<enName>
  &dept=<sales|pm|gm|assistant|shipping>      ← 新增
  &role=<manager|sales|assistant|shipping|pm|pmo|admin>   ← 新增
  &tutorialDone=<0|1>
```

ProjFlow 收到後**只能把 URL 的 `email`（與 `u`）當作「宣稱的身份」**,拿去 `profiles` 表查出**伺服器端**的 `dept` / `role`,再寫進 session。

> 🔴 **安全鐵則(務必照做,這是目前最嚴重的漏洞來源)**
>
> **1. 網域 ≠ 授權。** 「是 `@tei-composites.com` 信箱」只代表「可能是同事」,**不代表有權使用系統**。
> 絕不可因為 email 是公司網域就放行 —— 這正是「不知者用公司信箱就被系統放行」的破洞。
>
> **2. `role` / `dept` 一律以伺服器 `profiles` 表為準,禁止採信 URL 帶來的值。**
> URL 上的 `&role=` `&dept=` 只能當「顯示提示」,**永遠不可寫進 session 當權限**。
> 否則任何人只要拼一條 `?email=任意@tei-composites.com&role=admin&dept=gm` 就能取得總經理全權。
>
> **3. 查不到 profile 的 email → 拒絕進入 + 進「待審核」佇列,禁止自動建檔(auto-provision)。**
> 新同事首次登入必須由經理/GM 核准並指派 `role` 後才可用;在核准前一律 `showAccessDenied()`。
>
> **4. URL 明碼身份只是原型;正式版必須改用「簽章 token(JWT/HMAC)」。**
> 未簽章的 URL 參數任何人都能偽造 id / email / role,等同無認證。簽章後伺服器才能驗證來源可信。
>
> 對應 code(收件端):
> ```js
> const claimedEmail = qp.get('email');                 // 只是「宣稱」
> const profile = await db.profiles.findByEmail(claimedEmail); // 伺服器查真身份
> if (!profile) return enqueuePendingApproval(claimedEmail);   // 未登錄 → 待審核,不放行
> if (!ALLOWED_ROLES.includes(profile.role)) return showAccessDenied();
> session = { id: profile.id, email: profile.email, dept: profile.dept, role: profile.role }; // 用 DB 的值,不是 URL 的
> ```

---

## 二、什麼同步、什麼不同步

### ✅ 全同步(雙向)

| 資料 | 為何同步 | 同步主鍵 |
|------|--------|---------|
| **聯絡簿(客戶)** | PM 端的專案 stakeholder 來自業務客戶 | `contact_id` + `(owner_dept, owner_email)` |
| **跨部任務** | 業務 → PM 的請求、PM → 業務的回報 | `task_id` + `crossId` |
| **訊息 / 聊天** | 三系統共用同一條對話串(已有 crossId 機制) | `message_id` + `crossId` |
| **使用者 profile** | name / enName / dept / role / tutorialDone | `email` + `dept` |

### ⚠️ 部分同步(條件式)

| 資料 | 同步條件 | 不同步部分 |
|------|---------|----------|
| **業務甘特** | 條目有綁 `proj_id`(對到 ProjFlow 專案)→ 同步進度 | 純內部時程(報價追蹤、客戶拜訪)→ 不同步 |
| **業助任務** | `kind = 'pm-related'`(業務交辦 PM 的)→ 同步 | `kind = 'internal'`(業務部內部分派)→ 不同步 |
| **全公司總覽** | 公司層級 KPI、人數、月營收 → 同步(read-only) | 業績明細、毛利 → 不同步 |

### ❌ 完全不同步(業務機密 / 業務獨有)

| 資料 | 為何不同步 |
|------|----------|
| **利潤分析** 頁 | 業績、毛利、佣金、客戶單價 — 業務財務機密,出業務系統就違規 |
| **品牌合作** 頁 | 業務跟品牌商談判進度 — 未成案前對外即洩漏 |
| **船務作業** 頁(EDI / 報關 / 海關 API) | 業務部船務專用,跟 PM 工作無關 |
| **業務團隊 / 權限** 頁 | 業務部內部組織與 RLS 設定 |
| **全員狀態** 頁 | 經理看「業務今天在做什麼」— 業務部內部管理工具 |

---

## 三、聯絡簿(客戶名單)同步機制

這是同步的**重頭戲**,規則最細。

### 3.1 每筆客戶的所有權欄位

```sql
contacts (
  contact_id    uuid PRIMARY KEY,
  company       text NOT NULL,        -- 公司名
  person_name   text,                 -- 聯絡人
  person_en     text,                 -- 英文名
  email         text,
  phone         text,
  industry      text,                 -- 11 種產業
  region        text,                 -- 11 區
  country       text,                 -- 30+ 國家
  tier          text,                 -- vip|partner|standard|new
  owner_email   text NOT NULL,        -- ← 負責業務的 email
  owner_dept    text NOT NULL,        -- ← 負責業務的 dept (永遠是 'sales')
  created_at    timestamptz,
  updated_at    timestamptz,
  cross_id      text UNIQUE           -- ← 三系統共享 ID
)
```

### 3.2 RLS:每個角色看到的範圍

```sql
-- 業務本人:只看自己 owner 的客戶
CREATE POLICY contacts_sales_own ON contacts
  FOR SELECT TO sales
  USING (
    owner_email = current_setting('app.user_email')
    AND owner_dept = current_setting('app.user_dept')
  );

-- 業務經理:看自己 + 自己團隊 sales 的客戶
CREATE POLICY contacts_manager_team ON contacts
  FOR SELECT TO manager
  USING (
    owner_dept = 'sales'
    AND owner_email IN (
      SELECT email FROM profiles
      WHERE dept = 'sales'
        AND manager_email = current_setting('app.user_email')
    )
  );

-- 業助 / 船務:看本部所有業務的客戶(協助業務需要)
CREATE POLICY contacts_assistant_shipping ON contacts
  FOR SELECT TO assistant, shipping
  USING (owner_dept = 'sales');

-- GM (admin):看全部
CREATE POLICY contacts_admin_all ON contacts
  FOR SELECT TO admin USING (true);
```

### 3.3 ProjFlow 端的客戶頁該怎麼長

每個 ProjFlow 使用者進入「客戶 / Stakeholder」頁時,看到的清單**必須跟業務系統看到的範圍一致**。

```js
// ProjFlow 客戶頁載入時
const me = currentUser;  // { email, dept, role }

// 直接打 TEi-Salesys 提供的 sync endpoint(或共享 Supabase)
const myContacts = await fetch(
  `https://salesys-api/contacts?dept=${me.dept}&email=${me.email}&role=${me.role}`
).then(r => r.json());

// 渲染清單
renderContactList(myContacts);
```

**這就是「客戶名單要對上各自獨立的頁面」的實作**:
- A 業務在 ProjFlow 客戶頁,只看到自己 owner 的客戶
- B 業務看自己的,不會看到 A 的
- 經理進 ProjFlow 客戶頁,看自己團隊的
- GM 看全公司

### 3.4 雙向同步事件

```
業務系統新增客戶 → POST /sync/contacts → ProjFlow 收到 → 寫入 contacts (cross_id 對應)
ProjFlow 新增專案 stakeholder → POST /sync/contacts → 業務系統收到 → 寫入 contacts (新建,owner 暫設為發起 PM)
雙邊任一邊更新 → PATCH /sync/contacts/<cross_id> → 對方同步更新 (last-write-wins,by updated_at)
```

---

## 四、跨部任務(`pm-related`)同步機制

業務經理 / 業務 可以開「跨部任務」,指定 dept 為 `pm`,這類任務雙邊都要看。

### 4.1 業務系統建任務時

```js
// 業務介面開任務
const task = {
  title: '請 PM 確認 Q4 出貨檔期',
  target_dept: 'pm',                          // ← 關鍵欄位
  target_email: 'pm-lead@tei.com.tw',
  from_dept: 'sales',
  from_email: currentUser.email,
  due_date: '2026-07-01',
  kind: 'pm-related',                         // ← 同步 flag
  cross_id: generateUUID(),
};

if (task.kind === 'pm-related') {
  await syncToProjFlow(task);                 // ← 推到 ProjFlow
}
```

### 4.2 ProjFlow 端的工作檯收件

```js
// ProjFlow 載入時 fetch 收件匣
const myTasks = await fetch(
  `https://salesys-api/tasks?to_dept=${me.dept}&to_email=${me.email}`
).then(r => r.json());

renderTasks(myTasks);
```

### 4.3 內部任務不同步(隱私分流)

```js
if (task.kind === 'internal') {
  // 純業助內部分派,不出業務系統
  // 不呼叫 syncToProjFlow
}
```

---

## 五、訊息 / 聊天(已有 crossId 機制,本文補充與 dept 對應)

訊息收件人 ID 改用 `(dept, email)` 二元組:

```js
sendMessage({
  cross_id: generateUUID(),
  from: { dept: 'sales', email: 'kai@tei.com.tw' },
  to:   { dept: 'pm',    email: 'pm-lead@tei.com.tw' },
  body: '...',
});
```

三系統(TEi-Salesys / ProjFlow / RTM)看的對話視窗以 `cross_id` 為主鍵,參與者用 `(dept, email)` 識別。

---

## 六、實作清單(ProjFlow 端 TODO)

1. ☐ profiles 表加 `dept` 與 `role` 欄位,從 SSO URL 寫入
2. ☐ 共用 Supabase `contacts` 表(或建獨立但同步),套用上述 RLS
3. ☐ 客戶 / Stakeholder 頁渲染:依登入者的 `(dept, email)` filter
4. ☐ 任務 inbox:依登入者的 `(dept, email)` 過濾 `target_dept` `target_email`
5. ☐ 訊息對話以 `cross_id` 為主鍵,參與者用 `(dept, email)`
6. ☐ SSO URL 收件邏輯:從 query string 讀 `dept` `role`,寫進 session
7. ☐ 翻頁回 TEi-Salesys 時也帶上 `dept` `role`(雙向 contract)

---

## 七、業務日報 → ProjFlow 同步機制

### 7.1 為什麼業務系統有「日報生成」按鈕

業務每天寫一份**完整的業務報告**(留在業務系統),系統提供一個按鈕:

> 📤 **生成日報並上傳到 ProjFlow**

點下去 → 系統自動篩出可上 ProjFlow 的內容 → 業務在 modal 預覽並可編輯 → 一鍵上傳。

業務報告原始版本**永遠留在業務系統**,ProjFlow 只看到篩過、業務確認過的版本。

### 7.2 限制:**僅接受日報**

- ✅ 日報(daily report)— 本機制處理
- ❌ 週報(weekly report)— **不接受**,請用 ProjFlow 內建週報模組或月報信件範本
- ❌ 月報、季報、年度報告 — 不接受

業務系統 UI 上**必須清楚標示這個限制**(目前在按鈕旁的提示文字 + modal 頂部黃色警示框)。

### 7.3 系統自動過濾規則

業務報告原文中,**符合以下 regex 的整行自動過濾**,不會出業務系統:

```js
const PROHIBITED = /(業績|毛利|淨利|佣金|單價|報價|售價|底價|成本|[¥$]\s*[\d,]+|\bNT\$|\bUSD\s*[\d,]|機密|品牌談判|議價|傭金)/;
```

過濾後,modal 會在「🚫 已自動過濾」段落列出**前 24 字 + 省略號**,讓業務確認哪幾行被擋下來(若擋錯可在原文修正後重新生成)。

### 7.4 上傳 payload schema(POST)

```http
POST https://pm-system-mauve.vercel.app/api/daily-report
Content-Type: application/json
Authorization: Bearer <salesys-jwt>

{
  "type": "daily-report",
  "date": "2026-06-16",
  "from": {
    "dept": "sales",
    "email": "kai@tei.com.tw",
    "name": "蔡欣沛"
  },
  "body": "* 拜訪 ACME 客戶談 Q4 出貨檔期\n* 跟 PM 部對 PRJ-2024 進度...\n* 跨部任務:請 PM 協助確認 PRJ-2031 規格",
  "cross_id": "dr-2026-06-16-a3f7q2"
}
```

ProjFlow 端的 endpoint 要做:
1. 驗證 `from.dept` 屬於可同步部門(目前只接受 `sales` 的日報)
2. 寫入 `daily_reports` 表,並在 PM 工作檯顯示為「**業務同步**」標記的段落
3. 回傳 ProjFlow 端的查看 URL,業務系統會顯示給操作者確認
4. 若同一個 `(from.email, date)` 已有日報 → 回 409,前端 toast 提示「已存在,本日不可重複上傳」

### 7.5 為什麼不接受週報

- 業務週報的數據粒度涵蓋業績、客戶單價、毛利等**整合性機密**,即便逐行過濾也容易漏
- 週報通常含「下週計畫」,涉及未公開商機
- 強制週報走另一條人工審核路徑,降低自動洩漏風險

### 7.6 預期工作流

```
業務(每天下班前)
  ↓
在業務系統「我的衝刺」頁面填整份業務報告
  ↓
點「生成日報並上傳到 ProjFlow」
  ↓
系統篩 → 顯示可同步預覽 + 已過濾項目清單
  ↓
業務檢查、補充、(可選)刪除不想上的行
  ↓
點「一鍵上傳到 ProjFlow」
  ↓
ProjFlow 收到 → 寫入 daily_reports → PM 可在工作檯看到「業務同步」段落
```

---

## 八、業務經理 ↔ 下屬:觀察 vs 隱私邊界

業務經理需要「全面觀察」下屬作業,但**不能侵犯個人隱私作業**。下表是兩邊的明確契約 — UI 上必須在「全員狀態」頁面以視覺化方式呈現給經理,讓經理清楚知道自己能看到 / 看不到什麼。

### 8.1 ✓ 經理看得到(全面觀察用)

| 項目 | 顆粒度 |
|------|--------|
| 業績達成率 / 案件進度 / 拜訪數 | 數字 + 排名 |
| 日報是否提交 + 字數 + 時間 + ProjFlow 同步狀態 | 狀態 + metadata,**不含原文** |
| 動作類型 timeline | 開啟頁面 / 拜訪打卡 / 派任務 等(類型 only,不含內容) |
| 全員 KPI 彙整 + 排名 | 部門 / 個人 |
| 跨部任務委派 + 完成狀態 | 任務標題 + 狀態,完成內容由負責人決定要不要分享 |
| 客戶清單範圍 | 經理 = 自己團隊所有 sales 的客戶 |
| 業務上傳到 ProjFlow 的日報版本 | **已過濾**版本,點按鈕跳轉 ProjFlow 查看 |

### 8.2 ✗ 經理看不到(個人隱私)

| 項目 | 為何擋下 |
|------|--------|
| 業務報告**原文** | 業務在業務系統寫的草稿,未上傳前僅本人可見 |
| 個人聊天訊息內容 | 只能看「誰跟誰聊」(metadata),**不能看訊息本身** |
| 個人筆記 / 私人附件 URL / 草稿 | 個人工作工具,屬於思考過程,不對外 |
| 業績明細的客戶單價 / 報價金額 | 業務財務機密,連經理也只看達成率不看單筆 |
| 業助對其他業務的協助內容 | 跨業務的私人請求,業助是中立資源 |
| UI 個人化設定 / 鍵盤快捷鍵 | 個人偏好 |
| 健康 / 請假具體原因 | 只看「在班 / 不在班」,不看細節 |

### 8.3 業務系統 UI 上的明示

業務系統 **必須在敏感欄位旁加 privacy badge**,讓業務知道哪些內容是「私人草稿」:

```html
<span class="privacy-badge">
  🔒 私人草稿 ‧ 經理看不到原文
</span>
```

目前已加 badge 的欄位:
- 業務報告原文 textarea (在「我的衝刺」頁)
- (未來)聊天視窗 — 需加「對話內容不上同步」標示
- (未來)個人筆記 — 同上

### 8.4 經理「全員狀態」頁面實作

1. **今日日報狀態表**(`<table>`):每行 = 一位下屬
   - 是否上傳 ✓✗(顏色標示)
   - 上傳時間
   - 字數(只有字數,**沒有內容**)
   - ProjFlow 同步狀態(已同步 / 同步中 / 未同步)
   - 「在 ProjFlow 查看」按鈕(跳轉到 ProjFlow 查看**過濾後的版本**)
2. **下屬動作 timeline**:倒序時間流
   - 只顯示動作**類型**,例「14:00 開啟業務報告」
   - **不顯示動作內容**,例不會有「寫了 287 字日報內容是...」
   - 不會出現任何訊息內容、文件 URL
3. **隱私邊界說明區塊**(`.privacy-boundary`):
   - 雙欄列出 ✓ 看得到 / ✗ 看不到
   - 紫色背景區分於一般 section,讓經理一眼看到「這個邊界是公司明定的」

### 8.5 RLS / API gateway 雙保險

UI 隱私只是第一層,API gateway 必須做白名單:

```sql
-- 經理只能讀「下屬上傳到 ProjFlow 的日報版本」,讀不到原文
CREATE POLICY daily_reports_manager_uploaded ON daily_reports
  FOR SELECT TO manager
  USING (
    status = 'uploaded'
    AND author_email IN (
      SELECT email FROM profiles
      WHERE manager_email = current_setting('app.user_email')
    )
  );

-- 業務報告原文 (`sales_report_drafts` 表) 只有本人能讀
CREATE POLICY sales_report_self_only ON sales_report_drafts
  FOR ALL TO authenticated
  USING (author_email = current_setting('app.user_email'));
-- 經理視角無法繞過(因為 RLS 不分 manager)
```

`sales_report_drafts` 跟 `daily_reports` 是**兩張表**:
- `sales_report_drafts` — 原文,只有作者本人 RLS 可讀寫
- `daily_reports` — 已過濾並上傳的版本,經理可讀(範圍 = 自己團隊)

API gateway 對 `/api/sales-report-drafts/*` 拒絕所有非作者本人的請求(即使帶 manager token)。

---

## 九、不同步資料的硬性界線(安全)

ProjFlow **絕對不應該**透過任何 endpoint 取得以下資料:
- 利潤 / 毛利 / 佣金 (profit_analysis 表)
- 品牌合作未公開項目 (brand_partnerships 表, status != 'published')
- 船務作業 EDI / 報關記錄 (shipping_ops 表)
- 業務團隊權限明細 (sales_role_matrix 表)
- 全員狀態的逐人位置 / 動作日誌 (sales_team_status 表)

業務系統 API gateway 必須對這些路徑做白名單檢查,即使呼叫方帶 valid token 也拒絕。

---

## 十、正式版上線時(取代原型階段)

- 廢除 URL 明碼帶 `(dept, email)` → 改用 **Supabase JWT** 內嵌
- JWT claims 內含 `dept` `role` `email` `name` `enName`
- RLS 政策從 JWT claims 讀,不再依賴 URL query string
- 共享 `profiles` 表為唯一身份來源,三系統 `auth.uid()` 對到同一個 user

---

**收到請回覆**:
1. profiles 表 schema 已加 `dept` `role` 並能從 SSO 寫入
2. contacts 表 RLS 已套用(業務 / 經理 / 業助船務 / GM 四檔)
3. 客戶頁 + 任務 inbox 已照 `(dept, email)` filter 渲染
4. 確認不會誤抓利潤 / 品牌合作 / 船務 / 全員狀態這些不該同步的資料
