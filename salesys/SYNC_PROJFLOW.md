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

ProjFlow 收到後寫進 session:`{ id, email, dept, role }`,**所有 RLS / 頁面 filter 都用這組值**。

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

## 七、不同步資料的硬性界線(安全)

ProjFlow **絕對不應該**透過任何 endpoint 取得以下資料:
- 利潤 / 毛利 / 佣金 (profit_analysis 表)
- 品牌合作未公開項目 (brand_partnerships 表, status != 'published')
- 船務作業 EDI / 報關記錄 (shipping_ops 表)
- 業務團隊權限明細 (sales_role_matrix 表)
- 全員狀態的逐人位置 / 動作日誌 (sales_team_status 表)

業務系統 API gateway 必須對這些路徑做白名單檢查,即使呼叫方帶 valid token 也拒絕。

---

## 八、正式版上線時(取代原型階段)

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
