# TEi-Salesys ‧ 衝刺艙 ‧ ProjFlow 變更規格

> **文件用途**:本文件提供 ProjFlow 後端應對前端原型 `teisale-prototype.html` 新增功能所需的 schema / RLS / API / profile 變更。  
> **變更分支**:`claude/fervent-ptolemy-zSq3U`  
> **前端原型版本**:`teisale-prototype.html`(本次新增 4 個分頁、2 個 tier、3 種資料表)

---

## 1. 變更總覽

| 類別 | 新增 | 修改 |
|------|------|------|
| **角色 tier** | `assistant` 業務助理 ‧ `shipping` 船務 | `tier_meta.adminScope` 含括兩個新 tier |
| **profiles 人員** | 業助 ×2、船務 ×1(placeholder) | — |
| **資料表** | `teisale.assistant_task` ‧ `teisale.shipping_item` ‧ `teisale.contact` | — |
| **分頁(UI)** | `overview`(GM 專屬) ‧ `assist` ‧ `shipping` ‧ `contacts` | `team`(對 exec 強化) ‧ `personal`(加入邀請業助按鈕) |
| **RLS policy** | 三個新表的 row-level security | `profiles.tier` enum 擴充 |

---

## 2. profiles 變更

### 2.1 `profiles.tier` enum 擴充

```sql
ALTER TYPE profile_tier ADD VALUE 'assistant';
ALTER TYPE profile_tier ADD VALUE 'shipping';
```

### 2.2 新增 profile rows(placeholder ‧ 待真實姓名填入)

| key (前端) | name | en | title | tier | unit | ext | emoji | id (placeholder) |
|-----|------|-----|-------|------|------|-----|-------|------|
| `lily` | 林莉莉 | Lily Lin | 業務助理 | `assistant` | 業務開發課 SD | 431 | 🐰 | `placeholder-assistant-1` |
| `mia` | 楊咪雅 | Mia Yang | 業務助理 | `assistant` | 業務開發課 SD | 432 | 🦋 | `placeholder-assistant-2` |
| `marco` | 周船仔 | Marco Chou | 船務 | `shipping` | 營運支援課 OPS | 441 | 🐳 | `placeholder-shipping-1` |

> ⚠️ **本輪確認保留佔位** ‧ 後續真名上線時需:
> 1. 更新 `personas[].id` 為 ProjFlow 真實 UUID
> 2. 同步替換姓名 / 英文名 / 分機 / emoji
> 3. 若姓名變動,在 `demoDropdown` 三個 `<button data-persona>` 同步調整
> 4. SQL migration 中 INSERT 佔位 profile 的 row 應對應替換

---

## 3. 新資料表 DDL

### 3.1 `teisale.assistant_task` — 業務助理任務

```sql
CREATE TABLE teisale.assistant_task (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by  uuid NOT NULL REFERENCES profiles(id),   -- 派發人(業務/主管/經理)
  assigned_to   uuid NOT NULL REFERENCES profiles(id),   -- 接收業助
  title         text NOT NULL CHECK (length(title) BETWEEN 1 AND 60),
  description   text CHECK (length(description) <= 500),
  status        text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','doing','done')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_assist_task_assignee ON teisale.assistant_task(assigned_to, status);
CREATE INDEX idx_assist_task_requester ON teisale.assistant_task(requested_by, status);
```

### 3.2 `teisale.shipping_item` — 船務進出貨

```sql
CREATE TABLE teisale.shipping_item (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by  uuid NOT NULL REFERENCES profiles(id),   -- 業務/主管/業助發起;船務僅接收
  type          text NOT NULL
                 CHECK (type IN ('inbound','outbound','sample')),  -- 進貨/出貨/樣本
  mode          text NOT NULL
                 CHECK (mode IN ('sea','air')),                    -- 海運/空運
  title         text NOT NULL CHECK (length(title) BETWEEN 1 AND 80),
  party         text,                                              -- 客戶 / 供應商名稱(自由文字或 FK contact)
  party_contact uuid REFERENCES teisale.contact(id) ON DELETE SET NULL, -- 可選 FK
  port          text,                                              -- 港口 / 機場(基隆港、桃園機場…)
  status        text NOT NULL DEFAULT 'requested'
                 CHECK (status IN ('requested','booked','customs','delivered')),
  -- 報關/海關欄位(船務填入後寫回)
  customs_no    text,                                              -- 報單號碼
  customs_date  date,                                              -- 報關日期
  bl_no         text,                                              -- 提單號碼 B/L 或 AWB
  eta           date,                                              -- 預計到貨日
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_ship_status ON teisale.shipping_item(status);
CREATE INDEX idx_ship_requester ON teisale.shipping_item(requested_by);
```

### 3.3 `teisale.contact` — 客戶 / 供應商聯絡簿

```sql
CREATE TABLE teisale.contact (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind          text NOT NULL CHECK (kind IN ('customer','supplier')),
  company       text NOT NULL,
  person        text,                                              -- 聯絡窗口姓名
  phone         text,
  email         text,
  address       text,
  owner         uuid REFERENCES profiles(id),                      -- 建檔/負責人
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_contact_kind ON teisale.contact(kind);
CREATE INDEX idx_contact_owner ON teisale.contact(owner);
```

---

## 4. RLS Policies(關鍵權限規則)

### 4.1 `assistant_task` — 三道規則

```sql
ALTER TABLE teisale.assistant_task ENABLE ROW LEVEL SECURITY;

-- 業助:只能看到自己被指派的任務(看不到派發人的 KPI/案件,只看到任務本身)
CREATE POLICY assist_task_assignee_read ON teisale.assistant_task
  FOR SELECT USING (
    assigned_to = auth.uid()
  );

-- 派發人(業務/主管/經理):只能看到自己派出的任務
CREATE POLICY assist_task_requester_read ON teisale.assistant_task
  FOR SELECT USING (
    requested_by = auth.uid()
  );

-- 經理 / GM:可以看全部(用於管理視角)
CREATE POLICY assist_task_admin_read ON teisale.assistant_task
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.tier IN ('manager','exec'))
  );

-- INSERT:任何非業助/船務 tier 可派發
CREATE POLICY assist_task_insert ON teisale.assistant_task
  FOR INSERT WITH CHECK (
    requested_by = auth.uid()
    AND EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.tier IN ('staff','supervisor','manager','exec'))
  );

-- UPDATE status:業助可在自己任務上推進;派發人可重啟
CREATE POLICY assist_task_update ON teisale.assistant_task
  FOR UPDATE USING (
    assigned_to = auth.uid() OR requested_by = auth.uid()
  );
```

### 4.2 `shipping_item` — 三道規則

```sql
ALTER TABLE teisale.shipping_item ENABLE ROW LEVEL SECURITY;

-- 船務:看所有船務單(主場)
CREATE POLICY ship_shipping_all ON teisale.shipping_item
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.tier = 'shipping')
  );

-- GM:看所有(觀察)
CREATE POLICY ship_exec_read ON teisale.shipping_item
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.tier = 'exec')
  );

-- 派發人:看自己發出的船務單
CREATE POLICY ship_requester_read ON teisale.shipping_item
  FOR SELECT USING (
    requested_by = auth.uid()
  );

-- 業助:只看「自己有協助過的派發人」之船務單
CREATE POLICY ship_assistant_filter ON teisale.shipping_item
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM teisale.assistant_task t
      WHERE t.assigned_to = auth.uid()
        AND t.requested_by = teisale.shipping_item.requested_by
    )
  );

-- INSERT:業務指揮鏈成員 + 業助 可發起;船務本身也可建
CREATE POLICY ship_insert ON teisale.shipping_item
  FOR INSERT WITH CHECK (
    requested_by = auth.uid()
    AND EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid()
                AND p.tier IN ('staff','supervisor','manager','assistant','shipping'))
  );

-- UPDATE:僅船務可推進 status / 寫報關欄位
CREATE POLICY ship_update_shipping_only ON teisale.shipping_item
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.tier = 'shipping')
  );
```

### 4.3 `contact` — 業助無權限

```sql
ALTER TABLE teisale.contact ENABLE ROW LEVEL SECURITY;

-- 讀:業務/主管/經理/船務/GM 皆可;業助無權
CREATE POLICY contact_read ON teisale.contact
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid()
            AND p.tier IN ('staff','supervisor','manager','exec','shipping'))
  );

-- 寫(INSERT/UPDATE/DELETE):業務/主管/經理/船務(GM 只讀)
CREATE POLICY contact_write ON teisale.contact
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid()
            AND p.tier IN ('staff','supervisor','manager','shipping'))
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid()
            AND p.tier IN ('staff','supervisor','manager','shipping'))
  );
```

---

## 5. 權限矩陣(完整)

> 表格欄位用 `R` = 讀、`W` = 讀寫、`O` = 自己派出/協助範圍受限、`—` = 無權限。

| 分頁 / 資料 | 業務 staff | 課長 supervisor | 經理 manager | GM exec | 業助 assistant | 船務 shipping |
|------|:----:|:----:|:----:|:----:|:----:|:----:|
| 我的衝刺 personal | W | W | W | — | — | — |
| 成本利潤 profit | W | W | W | — | — | — |
| 案件時程 gantt | W | W | W | — | — | — |
| 品牌合作 brand | W | W | W | R | — | — |
| 團隊看板 team | — | R | R | R | — | — |
| 權限管理 admin | — | — | W | W | — | — |
| **全公司總覽 overview** | — | — | — | R | — | — |
| **協助任務 assist** | O 自己派出 | O 自己派出 | O 自己派出 | R 全部 | W 自己被指派 | — |
| **船務作業 shipping** | — | — | — | R 觀察 | O 自己協助過的派發人 | W 主場 |
| **聯絡簿 contacts** | W | W | W | R | — | W |

---

## 6. 預設停留分頁(per tier)

| tier | 預設分頁 | 備註 |
|------|---------|------|
| staff | `personal` | 業務本人衝刺艙 |
| supervisor | `personal` | 課長 / 副課長 |
| manager | `personal` | 業務經理 |
| exec | `overview` | **新**:GM 進系統先看跨職能總覽 |
| assistant | `assist` | 業助直接進收件匣 |
| shipping | `shipping` | 船務直接進進出貨看板 |

---

## 7. 跨表 view / RPC(建議)

### 7.1 GM 全公司總覽聚合 view

```sql
CREATE OR REPLACE VIEW teisale.v_company_overview AS
SELECT
  (SELECT count(*) FROM teisale.deal WHERE status NOT IN ('paid','lost'))      AS deals_active,
  (SELECT count(*) FROM teisale.assistant_task WHERE status != 'done')         AS assist_pending,
  (SELECT count(*) FROM teisale.assistant_task)                                AS assist_total,
  (SELECT count(*) FROM teisale.shipping_item WHERE status IN ('requested','booked','customs')) AS ship_in_transit,
  (SELECT count(*) FROM teisale.shipping_item WHERE status = 'requested')      AS ship_requested,
  (SELECT count(*) FROM teisale.shipping_item WHERE status = 'booked')         AS ship_booked,
  (SELECT count(*) FROM teisale.shipping_item WHERE status = 'customs')        AS ship_customs,
  (SELECT count(*) FROM teisale.shipping_item WHERE status = 'delivered')      AS ship_delivered;
```

### 7.2 業助任務派發 RPC(含資料隔離保證)

```sql
CREATE OR REPLACE FUNCTION teisale.assign_task(
  p_assignee uuid,
  p_title    text,
  p_desc     text DEFAULT ''
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE new_id uuid;
BEGIN
  -- 驗證接收方必須是 assistant tier
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_assignee AND tier = 'assistant') THEN
    RAISE EXCEPTION '接收人必須為業務助理 tier';
  END IF;

  -- 驗證派發方必須在指揮鏈內
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND tier IN ('staff','supervisor','manager','exec')) THEN
    RAISE EXCEPTION '只有業務指揮鏈成員可派發任務';
  END IF;

  INSERT INTO teisale.assistant_task (requested_by, assigned_to, title, description)
  VALUES (auth.uid(), p_assignee, p_title, p_desc)
  RETURNING id INTO new_id;

  RETURN new_id;
END;
$$;
```

---

## 8. ProjFlow 前端對應 API endpoints(建議)

| 動作 | endpoint | RLS 自動處理 |
|------|----------|------|
| 列出我相關的業助任務 | `GET /teisale/assistant_task` | ✅ |
| 派發業助任務 | `POST /teisale/rpc/assign_task` | ✅ |
| 推進業助任務狀態 | `PATCH /teisale/assistant_task/:id` | ✅ |
| 列出船務看板 | `GET /teisale/shipping_item` | ✅ |
| 建立船務單 | `POST /teisale/shipping_item` | ✅ |
| 船務推進 status / 寫報關 | `PATCH /teisale/shipping_item/:id` | ✅ |
| 列出聯絡人 | `GET /teisale/contact?kind=customer\|supplier` | ✅ |
| 新增聯絡人 | `POST /teisale/contact` | ✅ |
| GM 全公司總覽 | `GET /teisale/v_company_overview` | ✅(view RLS) |

---

## 9. 前端原型對應檔案位置

| 區塊 | 行數(近似) | 說明 |
|------|------|------|
| `personas` 新人員 | `~2275-2330` | lily / mia / marco |
| `tierMeta` 新 tier | `~2540-2560` | assistant / shipping |
| `tierRank` 排序 | `~2640` | 兩個新 tier rank = -1(sideways) |
| nav-tabs 新按鈕 | `~1268-1289` | overview / assist / shipping / contacts |
| 新分頁 sections | `~2090-2380` | 完整 HTML 在 admin section 之後 |
| 個人頁邀請業助 | `~1400-1430` | personal 分頁底部 |
| Demo 切換器 | `~2700-2715` | 新增 3 個 persona 按鈕 |
| Render 函式 | `~3290-3700` | renderOverview / renderAssist / renderShipping / renderContacts |
| 3 個 mini-modal | `~2700-2790` | inviteAssist / newShip / newContact |

---

## 10. ProjFlow 端 ToDo 清單

依執行順序排列。每一項都對應上述章節:

1. **DDL Migration**(章節 2.1, 3.1, 3.2, 3.3)
   - `ALTER TYPE profile_tier ADD VALUE ...`
   - `CREATE TABLE` × 3
2. **RLS Policies**(章節 4.1, 4.2, 4.3)
3. **Seed placeholder profiles**(章節 2.2)— 真實姓名待補
4. **View / RPC**(章節 7.1, 7.2)
5. **API routing**(章節 8)
6. **ProjFlow 前端`profiles` 帶入邏輯**:將 `tier` 為 `assistant` / `shipping` 的人員預設視角分頁與既有 staff/supervisor/manager/exec 平行處理
7. **i18n strings**(若 ProjFlow 有 i18n):新增「業務助理 / 船務 / 全公司總覽 / 協助任務 / 船務作業 / 聯絡簿」對應 en-US

---

## 11. ProjFlow 同步寫入規則(critical ‧ 避免資料錯亂)

**核心原則**:每個 tier 只寫入自己職能對應的表;觀察頁面一律唯讀,前端不會觸發 `INSERT/UPDATE`。

### 11.1 各 tier 的寫入範圍

| tier | 可寫入 ProjFlow 表 | 唯讀(觀察) |
|------|---------------------|----------------|
| `staff` 業務 | `kpi_events` ‧ `reception_visits` ‧ `teisale.deal` ‧ `teisale.contact` ‧ `teisale.assistant_task`(派發) ‧ `teisale.shipping_item`(發起) | — |
| `supervisor` 課長 | 同上(自己的) | 團隊看板(`team` page)|
| `manager` 經理 | 同上(自己的) + `profiles.tier`(調整下屬權限) | **全員狀態(`team_full` page) ‧ 業助任務全表 ‧ 船務全表** |
| `exec` 總經理 | **不寫入任何表** | 所有頁面 |
| `assistant` 業助 | `teisale.assistant_task`(只更新自己被指派的 status) | — |
| `shipping` 船務 | `teisale.shipping_item`(status / customs_no / customs_date / bl_no / eta) ‧ `teisale.contact` | — |

### 11.2 頁面 ↔ 寫入目標映射

> 此表用於前端在每個頁面顯示「sync target 標籤」與「READ-ONLY banner」。

| 前端頁面 | 寫入 ProjFlow | 在 UI 顯示 |
|----------|---------------|-----------|
| `personal` 我的衝刺 | `kpi_events` / `reception_visits` / `teisale.deal` | 黃色 sync-target tag |
| `profit` 成本利潤 | `teisale.deal`(更新收款/成本) | 黃色 sync-target tag |
| `gantt` 案件時程 | `teisale.deal`(更新 status / dates) | 黃色 sync-target tag |
| `brand` 品牌合作 | `teisale.brand_partnership`(暫定) | 黃色 sync-target tag |
| **`team` 團隊看板** | **無** | 藍色 READ-ONLY banner |
| **`team_full` 全員狀態** | **無** | 藍色 READ-ONLY banner |
| **`overview` 全公司總覽** | **無** | 藍色 READ-ONLY banner |
| `admin` 權限管理 | `profiles.tier` | 黃色 sync-target tag |
| `assist` 協助任務 | `teisale.assistant_task` | 黃色 sync-target tag(業助/派發人) |
| `shipping` 船務作業 | `teisale.shipping_item` | 黃色 sync-target tag(船務) |
| `contacts` 聯絡簿 | `teisale.contact` | 黃色 sync-target tag(GM 為藍色 READ-ONLY) |

### 11.3 防呆原則(後端 enforcement)

即使前端誤判,RLS policies 必須阻擋:

1. **業助/船務 不能寫入 `kpi_events` / `reception_visits` / `teisale.deal`**
   ```sql
   CREATE POLICY deal_write_block_non_sales ON teisale.deal
     FOR INSERT WITH CHECK (
       EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid()
               AND p.tier IN ('staff','supervisor','manager'))
     );
   -- kpi_events / reception_visits 同樣阻擋
   ```

2. **GM(exec) 不能寫入任何 teisale.* 業務表**(完全觀察身分)
   ```sql
   CREATE POLICY teisale_deal_block_exec ON teisale.deal
     FOR INSERT, UPDATE, DELETE
     USING (
       NOT EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.tier = 'exec')
     );
   -- 對 assistant_task / shipping_item / contact 同樣處理
   ```

3. **觀察頁面送來的 PATCH 一律拒絕**
   - 後端 API 層應在 `team` / `team_full` / `overview` 對應的 endpoint 不開放 `PATCH`/`POST`
   - 即使前端誤送,API 層回 405 Method Not Allowed

### 11.4 經理視角的關鍵分離

> 解決客戶提出的「經理不便、避免資訊錯亂」問題:

- **`personal` 頁** = 經理「自己的業績/拜訪/案件」 → **會寫入 ProjFlow**
- **`team_full` 頁(新)** = 經理「觀察全員狀態」(BXD 業務 + 業助 + 船務) → **不寫入 ProjFlow**
- 兩頁面以**不同分頁 tab** 區隔,UI 上以 sync-target tag 與 READ-ONLY banner 明示
- 經理在 `team_full` 看到的「別人的業績」是 ProjFlow 透過 RLS 聚合的唯讀資料,**經理無權更新他人 `kpi_events`**

---

## 12. 業助/船務 對 ProjFlow 的同步行為(常見問題)

**Q: 業助跟船務在 ProjFlow 是否沒有東西可同步?**  
**A: 有,但同步到的是新表,不會混入業務的同步資料表。**

### 12.1 業助的同步行為

| 動作 | ProjFlow 寫入 |
|------|---------------|
| 接到任務後標記「處理中」 | `UPDATE teisale.assistant_task SET status='doing', updated_at=now() WHERE assigned_to=auth.uid() AND id=$1` |
| 完成任務 | 同上,status='done' |
| 暫無附件上傳功能(下一輪) | — |

業助 **不會**寫入 `kpi_events`、`reception_visits`、`teisale.deal`、`teisale.contact`,也**看不到**這些表的內容(RLS 阻擋)。

### 12.2 船務的同步行為

| 動作 | ProjFlow 寫入 |
|------|---------------|
| 接到進出貨需求後「訂艙」 | `UPDATE teisale.shipping_item SET status='booked', updated_at=now()` |
| 提交報關 | `UPDATE teisale.shipping_item SET status='customs', customs_no=$1, customs_date=$2, bl_no=$3` |
| 標記到貨 | `UPDATE teisale.shipping_item SET status='delivered', eta=$1` |
| 新增/編輯客戶或供應商 | `INSERT/UPDATE teisale.contact` |
| 新建船務單(由船務發起) | `INSERT INTO teisale.shipping_item (requested_by, type, mode, ...)` 其中 `requested_by` = 船務自己 |

船務 **不會**寫入 `kpi_events`、`reception_visits`、`teisale.deal`、`teisale.assistant_task`。

### 12.3 結論:資料表所有權清單

```
sales 數據(業務指揮鏈獨佔寫入):
  kpi_events            <- staff / supervisor / manager
  reception_visits      <- staff / supervisor / manager
  teisale.deal          <- staff / supervisor / manager

協助任務:
  teisale.assistant_task  
    INSERT <- staff / supervisor / manager / exec(透過 RPC assign_task)
    UPDATE status <- assistant(只能改自己被指派的) + requester(取消/重啟)

船務數據:
  teisale.shipping_item
    INSERT <- staff / supervisor / manager / assistant / shipping
    UPDATE status / customs / bl_no <- shipping ONLY

聯絡簿:
  teisale.contact
    INSERT / UPDATE / DELETE <- staff / supervisor / manager / shipping
    SELECT <- 上述 + exec(只讀)

權限資料:
  profiles.tier <- manager(對下層) / exec(全部)
```

每個表的寫入權限互不重疊,因此 **不可能發生「經理在觀察別人時誤觸寫入造成 ProjFlow 資料錯亂」** 的情境 — RLS 在資料庫層攔截,前端 UI 透過 banner + sync-target tag 明示。

---

## 13. 聯絡簿 ‧ 產業 + 區域國家分類(2026-06-08 擴充)

**對應 migration:** `migrations/2026-06-08-teisale-contact-industry-region.sql`

### 13.1 新增欄位

```sql
ALTER TABLE teisale.contact
  ADD COLUMN industry text,   -- 產業代碼
  ADD COLUMN region   text,   -- 區域代碼
  ADD COLUMN country  text;   -- ISO-2 國家代碼
```

### 13.2 產業別字典(11 種)

| code | label | 對應前端 emoji |
|------|-------|--------------|
| `aero`   | 航太         | ✈️ |
| `auto`   | 汽車         | 🏎️ |
| `moto`   | 重機         | 🏍️ |
| `cycle`  | 自行車/運動   | 🚴 |
| `ev`     | 電動車/能源   | 🔋 |
| `ind`    | 工業/機械     | 🏭 |
| `med`    | 醫療         | ⚕️ |
| `def`    | 國防         | 🛡️ |
| `marine` | 海事/船舶     | ⛵ |
| `elec`   | 消費電子      | 📱 |
| `other`  | 其他         | 📦 |

### 13.3 區域 → 國家結構(層級 11 區 ‧ 30+ 國家)

| region | label | 國家(ISO-2) |
|--------|-------|------------|
| `tw`  | 台灣   | TW |
| `ea`  | 東亞   | JP, KR, CN, HK |
| `sea` | 東南亞 | TH, VN, SG, MY, ID, PH |
| `sa`  | 南亞   | IN |
| `na`  | 北美   | US, CA, MX |
| `eu`  | 歐洲   | DE, UK, FR, IT, ES, NL, SE, CH |
| `oc`  | 大洋洲 | AU, NZ |
| `me`  | 中東   | AE, SA, IL, TR |
| `la`  | 拉美   | BR, AR, CL |
| `af`  | 非洲   | ZA |
| `other` | 其他 | _(未分類)_ |

### 13.4 CHECK 約束 + 索引

- `contact_industry_chk`:industry 必為白名單之一
- `contact_region_chk`:region 必為白名單之一
- 三個欄位各加 partial index(WHERE col IS NOT NULL)
- 複合索引 `(industry, region)` 支援「同產業同區域客戶」查詢

### 13.5 新增 view

```sql
teisale.v_contact_by_industry  -- 依產業彙整 客戶/供應商 計數
teisale.v_contact_by_region    -- 依 region+country 彙整
```

### 13.6 v_company_overview 擴充

新增 5 個欄位:
- `contact_with_industry`(已分產業的聯絡人數)
- `contact_with_region`(已分區域的聯絡人數)
- `distinct_industries`(出現過的產業數,最多 11)
- `distinct_regions`(出現過的區域數,最多 11)
- `distinct_countries`(出現過的國家數)

GM dashboard 可用這幾個欄位顯示「**聯絡簿分類覆蓋率**」與「**業務拓展廣度**」。

### 13.7 前端 UI 變更摘要

- 「新增聯絡人」modal 加 3 個下拉:產業、區域、國家(區域→國家連動)
- 聯絡簿頁加篩選列:產業 pill row + 區域 pill row,自動顯示 count
- 表格新增 2 欄:「產業」+「區域 / 國家」(以彩色 chip 呈現)
- 多維度同時篩選:類型(客戶/供應商)+ 產業 + 區域

---

## 14. 未涵蓋(下一輪)

以下功能本次原型 **未實作**,但 ProjFlow 可預先規劃 schema:

- 業助任務的 **附件** / **檔案連結**(目前只有 text desc)
- 船務 **報關文件上傳**(customs_doc_url 欄位、storage bucket)
- 聯絡人 **多窗口**(目前 1 person/contact;之後可拆 sub-table)
- 業助任務的 **截止日**(due_at)與提醒
- 船務 **EDI / 海關 API** 串接(目前手動更新 status)
- 跨職能 **chat 群組**(目前 chat 只有 BXD 業務群)

---

> 結束。任何欄位 / 規則有疑問,請以本前端原型實際行為為準(`teisale-prototype.html` 在 `claude/fervent-ptolemy-zSq3U` 分支)。
