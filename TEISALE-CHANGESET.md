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

| key (前端) | name | en | title | tier | unit | ext | emoji |
|-----|------|-----|-------|------|------|-----|-------|
| `lily` | 林莉莉 | Lily Lin | 業務助理 | `assistant` | 業務開發課 SD | 431 | 🐰 |
| `mia` | 楊咪雅 | Mia Yang | 業務助理 | `assistant` | 業務開發課 SD | 432 | 🦋 |
| `marco` | 周船仔 | Marco Chou | 船務 | `shipping` | 營運支援課 OPS | 441 | 🐳 |

> ⚠️ `id` 欄位前端目前用 `placeholder-assistant-1` 等占位字串,正式部署時請替換為 ProjFlow 真實 UUID。

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

## 11. 未涵蓋(下一輪)

以下功能本次原型 **未實作**,但 ProjFlow 可預先規劃 schema:

- 業助任務的 **附件** / **檔案連結**(目前只有 text desc)
- 船務 **報關文件上傳**(customs_doc_url 欄位、storage bucket)
- 聯絡人 **多窗口**(目前 1 person/contact;之後可拆 sub-table)
- 業助任務的 **截止日**(due_at)與提醒
- 船務 **EDI / 海關 API** 串接(目前手動更新 status)
- 跨職能 **chat 群組**(目前 chat 只有 BXD 業務群)

---

> 結束。任何欄位 / 規則有疑問,請以本前端原型實際行為為準(`teisale-prototype.html` 在 `claude/fervent-ptolemy-zSq3U` 分支)。
