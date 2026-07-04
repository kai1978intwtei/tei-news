-- =============================================================================
-- TEi-Salesys ‧ 衝刺艙 — ProjFlow Migration
-- File:    2026-05-28-teisale-assistant-shipping-contacts.sql
-- Branch:  claude/fervent-ptolemy-zSq3U
-- Author:  TEi-Salesys 衝刺艙原型 v2
-- Target:  ProjFlow PostgreSQL (Supabase-style auth.uid())
--
-- 本 migration 對應前端 teisale-prototype.html 的下列功能新增:
--   1. 業務助理 (assistant) 與船務 (shipping) 兩個新 tier
--   2. teisale.assistant_task    業助任務(含截止日 + 附件)
--   3. teisale.shipping_item     船務進出貨(含報關 + EDI 欄位)
--   4. teisale.contact           客戶/供應商聯絡簿
--   5. RLS policies(資料寫入嚴格隔離,避免經理觀察時誤觸寫入)
--   6. v_company_overview view + assign_task RPC
--
-- 執行方式(以 supabase CLI 為例):
--   supabase db push --include 2026-05-28-teisale-assistant-shipping-contacts.sql
-- 或在 Postgres psql 直接:
--   \i 2026-05-28-teisale-assistant-shipping-contacts.sql
--
-- 本 migration 採 idempotent 策略(IF NOT EXISTS / DROP POLICY IF EXISTS),
-- 可重複執行不會失敗。
-- =============================================================================

-- 注意:enum 新增值(ALTER TYPE ... ADD VALUE)必須在交易之外先行提交,
-- 否則同一交易稍後的 seed INSERT 使用新值會觸發 PostgreSQL 55P04
-- "unsafe use of new value of enum type"。故本段刻意放在交易 BEGIN; 之前(autocommit)。

-- -----------------------------------------------------------------------------
-- 1. profile_tier enum:擴充 assistant / shipping
-- -----------------------------------------------------------------------------
-- 假設 ProjFlow 既有 enum 名為 profile_tier;若名稱不同請在這裡調整。
-- 若使用 TEXT + CHECK,本步驟改為更新 CHECK 約束。

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'profile_tier') THEN
    CREATE TYPE profile_tier AS ENUM ('staff','supervisor','manager','exec','assistant','shipping');
  ELSE
    -- PostgreSQL 12+:ADD VALUE IF NOT EXISTS
    ALTER TYPE profile_tier ADD VALUE IF NOT EXISTS 'assistant';
    ALTER TYPE profile_tier ADD VALUE IF NOT EXISTS 'shipping';
  END IF;
END $$;

-- enum 已在交易外提交,以下 DDL/DML 進入單一交易
BEGIN;


-- -----------------------------------------------------------------------------
-- 2. teisale.contact  客戶 / 供應商聯絡簿
--    (需先於 shipping_item 之前建立,因為後者 FK 到此表)
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS teisale;

CREATE TABLE IF NOT EXISTS teisale.contact (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind          text NOT NULL CHECK (kind IN ('customer','supplier')),
  company       text NOT NULL,
  person        text,
  phone         text,
  email         text,
  address       text,
  owner         uuid REFERENCES public.profiles(id),
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_contact_kind  ON teisale.contact(kind);
CREATE INDEX IF NOT EXISTS idx_contact_owner ON teisale.contact(owner);


-- -----------------------------------------------------------------------------
-- 3. teisale.assistant_task  業助任務(含截止日 + 附件)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS teisale.assistant_task (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by  uuid NOT NULL REFERENCES public.profiles(id),
  assigned_to   uuid NOT NULL REFERENCES public.profiles(id),
  title         text NOT NULL CHECK (length(title) BETWEEN 1 AND 60),
  description   text CHECK (description IS NULL OR length(description) <= 500),
  status        text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','doing','done')),
  -- Item 1 新增:截止日 + 附件
  due_at        date,
  attachments   jsonb NOT NULL DEFAULT '[]'::jsonb,
                 -- 結構:[{ "name": "客戶報表", "url": "https://..." }, ...]
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_assist_assignee  ON teisale.assistant_task(assigned_to, status);
CREATE INDEX IF NOT EXISTS idx_assist_requester ON teisale.assistant_task(requested_by, status);
CREATE INDEX IF NOT EXISTS idx_assist_due_at    ON teisale.assistant_task(due_at) WHERE due_at IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 4. teisale.shipping_item  船務進出貨(含報關 + EDI 欄位)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS teisale.shipping_item (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by  uuid NOT NULL REFERENCES public.profiles(id),
  type          text NOT NULL CHECK (type IN ('inbound','outbound','sample')),
  mode          text NOT NULL CHECK (mode IN ('sea','air')),
  title         text NOT NULL CHECK (length(title) BETWEEN 1 AND 80),
  party         text,
  party_contact uuid REFERENCES teisale.contact(id) ON DELETE SET NULL,
  port          text,
  status        text NOT NULL DEFAULT 'requested'
                 CHECK (status IN ('requested','booked','customs','delivered')),
  -- Item 2 新增:報關 + EDI 欄位
  customs_no       text,           -- 報單號碼
  customs_date     date,           -- 報關日期
  bl_no            text,           -- 提單號碼 B/L 或 AWB
  eta              date,           -- 預計到貨日
  customs_doc_url  text,           -- 報關文件雲端連結
  customs_notes    text,
  edi_status       text CHECK (edi_status IS NULL OR edi_status IN ('pending','submitted','cleared','rejected')),
  edi_synced_at    timestamptz,    -- 最近 EDI 同步時間
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ship_status      ON teisale.shipping_item(status);
CREATE INDEX IF NOT EXISTS idx_ship_requester   ON teisale.shipping_item(requested_by);
CREATE INDEX IF NOT EXISTS idx_ship_edi_status  ON teisale.shipping_item(edi_status) WHERE edi_status IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_ship_eta         ON teisale.shipping_item(eta) WHERE eta IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 5. updated_at 自動更新 trigger(共用)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION teisale.touch_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_assist_task_touch ON teisale.assistant_task;
CREATE TRIGGER trg_assist_task_touch BEFORE UPDATE ON teisale.assistant_task
  FOR EACH ROW EXECUTE FUNCTION teisale.touch_updated_at();

DROP TRIGGER IF EXISTS trg_ship_item_touch ON teisale.shipping_item;
CREATE TRIGGER trg_ship_item_touch BEFORE UPDATE ON teisale.shipping_item
  FOR EACH ROW EXECUTE FUNCTION teisale.touch_updated_at();

DROP TRIGGER IF EXISTS trg_contact_touch ON teisale.contact;
CREATE TRIGGER trg_contact_touch BEFORE UPDATE ON teisale.contact
  FOR EACH ROW EXECUTE FUNCTION teisale.touch_updated_at();


-- =============================================================================
-- 6. Row-Level Security
-- =============================================================================

-- 6.1 啟用 RLS
ALTER TABLE teisale.assistant_task ENABLE ROW LEVEL SECURITY;
ALTER TABLE teisale.shipping_item  ENABLE ROW LEVEL SECURITY;
ALTER TABLE teisale.contact        ENABLE ROW LEVEL SECURITY;

-- 共用:取得當前使用者 tier
CREATE OR REPLACE FUNCTION teisale.my_tier() RETURNS text AS $$
  SELECT tier::text FROM public.profiles WHERE id = auth.uid()
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public;


-- -----------------------------------------------------------------------------
-- 6.2 teisale.assistant_task policies
-- -----------------------------------------------------------------------------

-- SELECT:接收業助 + 派發人 + 經理/GM 都能看
DROP POLICY IF EXISTS assist_task_select ON teisale.assistant_task;
CREATE POLICY assist_task_select ON teisale.assistant_task
  FOR SELECT USING (
    assigned_to = auth.uid()
    OR requested_by = auth.uid()
    OR teisale.my_tier() IN ('manager','exec')
  );

-- INSERT:業務指揮鏈成員(不含業助/船務/GM)可派發
DROP POLICY IF EXISTS assist_task_insert ON teisale.assistant_task;
CREATE POLICY assist_task_insert ON teisale.assistant_task
  FOR INSERT WITH CHECK (
    requested_by = auth.uid()
    AND teisale.my_tier() IN ('staff','supervisor','manager')
  );

-- UPDATE:業助可改自己任務的 status / 派發人可重啟或取消
DROP POLICY IF EXISTS assist_task_update ON teisale.assistant_task;
CREATE POLICY assist_task_update ON teisale.assistant_task
  FOR UPDATE USING (
    assigned_to = auth.uid() OR requested_by = auth.uid()
  );

-- DELETE:僅派發人可刪除自己派出的任務
DROP POLICY IF EXISTS assist_task_delete ON teisale.assistant_task;
CREATE POLICY assist_task_delete ON teisale.assistant_task
  FOR DELETE USING (requested_by = auth.uid());


-- -----------------------------------------------------------------------------
-- 6.3 teisale.shipping_item policies
-- -----------------------------------------------------------------------------

-- SELECT:船務看全部 / GM 看全部 / 派發人看自己派的 / 業助看自己協助過的派發人之船務單
DROP POLICY IF EXISTS ship_select ON teisale.shipping_item;
CREATE POLICY ship_select ON teisale.shipping_item
  FOR SELECT USING (
    teisale.my_tier() IN ('shipping','exec','manager')
    OR requested_by = auth.uid()
    OR EXISTS (
      SELECT 1 FROM teisale.assistant_task t
      WHERE t.assigned_to = auth.uid()
        AND t.requested_by = teisale.shipping_item.requested_by
    )
  );

-- INSERT:業務鏈 + 業助 + 船務可發起;GM 不可寫
DROP POLICY IF EXISTS ship_insert ON teisale.shipping_item;
CREATE POLICY ship_insert ON teisale.shipping_item
  FOR INSERT WITH CHECK (
    requested_by = auth.uid()
    AND teisale.my_tier() IN ('staff','supervisor','manager','assistant','shipping')
  );

-- UPDATE:僅船務可推進 status / 寫報關欄位;派發人僅可改 title/notes(防止 GM 誤改)
DROP POLICY IF EXISTS ship_update_shipping_full ON teisale.shipping_item;
CREATE POLICY ship_update_shipping_full ON teisale.shipping_item
  FOR UPDATE USING (teisale.my_tier() = 'shipping');

DROP POLICY IF EXISTS ship_update_requester_limited ON teisale.shipping_item;
CREATE POLICY ship_update_requester_limited ON teisale.shipping_item
  FOR UPDATE USING (
    requested_by = auth.uid() AND teisale.my_tier() IN ('staff','supervisor','manager','assistant')
  );

-- DELETE:僅船務可刪
DROP POLICY IF EXISTS ship_delete ON teisale.shipping_item;
CREATE POLICY ship_delete ON teisale.shipping_item
  FOR DELETE USING (teisale.my_tier() = 'shipping');


-- -----------------------------------------------------------------------------
-- 6.4 teisale.contact policies(GM 只讀;業助無權限)
-- -----------------------------------------------------------------------------

-- SELECT:業務鏈 + GM(只讀) + 船務皆可讀;業助不可
DROP POLICY IF EXISTS contact_select ON teisale.contact;
CREATE POLICY contact_select ON teisale.contact
  FOR SELECT USING (
    teisale.my_tier() IN ('staff','supervisor','manager','exec','shipping')
  );

-- INSERT/UPDATE/DELETE:業務鏈 + 船務可寫;GM/業助不可寫
DROP POLICY IF EXISTS contact_insert ON teisale.contact;
CREATE POLICY contact_insert ON teisale.contact
  FOR INSERT WITH CHECK (
    teisale.my_tier() IN ('staff','supervisor','manager','shipping')
  );

DROP POLICY IF EXISTS contact_update ON teisale.contact;
CREATE POLICY contact_update ON teisale.contact
  FOR UPDATE USING (
    teisale.my_tier() IN ('staff','supervisor','manager','shipping')
  );

DROP POLICY IF EXISTS contact_delete ON teisale.contact;
CREATE POLICY contact_delete ON teisale.contact
  FOR DELETE USING (
    teisale.my_tier() IN ('staff','supervisor','manager','shipping')
  );


-- =============================================================================
-- 7. 防呆:GM (exec) 無權寫入既有業務資料表
--    若 teisale.deal / kpi_events / reception_visits 已存在 policy,
--    這裡用 ADD POLICY 補上「exec 阻擋」規則,而非覆寫既有。
-- =============================================================================
-- 注意:以下假設 teisale.deal / public.kpi_events / public.reception_visits 已存在。
-- 若名稱或 schema 不同,請對應修改。
-- 採 PERMISSIVE 模式 + RESTRICTIVE 模式組合:exec 既無 INSERT 又無 UPDATE。

DO $$
BEGIN
  -- 只在表存在時加 policy
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='teisale' AND table_name='deal') THEN
    EXECUTE 'DROP POLICY IF EXISTS deal_block_exec_write ON teisale.deal';
    EXECUTE 'CREATE POLICY deal_block_exec_write ON teisale.deal AS RESTRICTIVE
             FOR INSERT WITH CHECK (teisale.my_tier() <> ''exec'')';
    EXECUTE 'DROP POLICY IF EXISTS deal_block_exec_update ON teisale.deal';
    EXECUTE 'CREATE POLICY deal_block_exec_update ON teisale.deal AS RESTRICTIVE
             FOR UPDATE USING (teisale.my_tier() <> ''exec'')';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='kpi_events') THEN
    EXECUTE 'DROP POLICY IF EXISTS kpi_block_exec_write ON public.kpi_events';
    EXECUTE 'CREATE POLICY kpi_block_exec_write ON public.kpi_events AS RESTRICTIVE
             FOR INSERT WITH CHECK (teisale.my_tier() <> ''exec'')';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='reception_visits') THEN
    EXECUTE 'DROP POLICY IF EXISTS visit_block_exec_write ON public.reception_visits';
    EXECUTE 'CREATE POLICY visit_block_exec_write ON public.reception_visits AS RESTRICTIVE
             FOR INSERT WITH CHECK (teisale.my_tier() <> ''exec'')';
  END IF;
END $$;


-- =============================================================================
-- 8. View ‧ 全公司總覽聚合(GM dashboard 用)
-- =============================================================================
CREATE OR REPLACE VIEW teisale.v_company_overview WITH (security_invoker = true) AS
SELECT
  (SELECT count(*) FROM teisale.assistant_task)                                AS assist_total,
  (SELECT count(*) FROM teisale.assistant_task WHERE status != 'done')         AS assist_pending,
  (SELECT count(*) FROM teisale.assistant_task WHERE due_at < current_date AND status != 'done') AS assist_overdue,
  (SELECT count(*) FROM teisale.shipping_item)                                 AS ship_total,
  (SELECT count(*) FROM teisale.shipping_item WHERE status = 'requested')      AS ship_requested,
  (SELECT count(*) FROM teisale.shipping_item WHERE status = 'booked')         AS ship_booked,
  (SELECT count(*) FROM teisale.shipping_item WHERE status = 'customs')        AS ship_customs,
  (SELECT count(*) FROM teisale.shipping_item WHERE status = 'delivered')      AS ship_delivered,
  (SELECT count(*) FROM teisale.shipping_item WHERE status IN ('requested','booked','customs')) AS ship_in_transit,
  (SELECT count(*) FROM teisale.contact WHERE kind='customer')                 AS contact_customers,
  (SELECT count(*) FROM teisale.contact WHERE kind='supplier')                 AS contact_suppliers;


-- =============================================================================
-- 9. RPC ‧ 業助任務派發(含驗證)
-- =============================================================================
CREATE OR REPLACE FUNCTION teisale.assign_task(
  p_assignee     uuid,
  p_title        text,
  p_description  text DEFAULT '',
  p_due_at       date DEFAULT NULL,
  p_attachments  jsonb DEFAULT '[]'::jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, teisale AS $$
DECLARE
  new_id uuid;
  assignee_tier text;
  caller_tier text;
BEGIN
  -- 驗證接收方必須是 assistant tier
  SELECT tier::text INTO assignee_tier FROM public.profiles WHERE id = p_assignee;
  IF assignee_tier IS NULL THEN
    RAISE EXCEPTION '接收人不存在(profile id=%)', p_assignee;
  END IF;
  IF assignee_tier <> 'assistant' THEN
    RAISE EXCEPTION '接收人 tier=%,必須為業務助理 (assistant)', assignee_tier;
  END IF;

  -- 驗證派發方必須在指揮鏈內(staff/supervisor/manager)
  caller_tier := teisale.my_tier();
  IF caller_tier NOT IN ('staff','supervisor','manager') THEN
    RAISE EXCEPTION '只有業務指揮鏈成員可派發任務(目前 tier=%)', caller_tier;
  END IF;

  -- 驗證附件 JSON 結構
  IF jsonb_typeof(p_attachments) <> 'array' THEN
    RAISE EXCEPTION 'attachments 必須為 JSON array';
  END IF;

  INSERT INTO teisale.assistant_task
    (requested_by, assigned_to, title, description, due_at, attachments)
  VALUES
    (auth.uid(), p_assignee, p_title, p_description, p_due_at, p_attachments)
  RETURNING id INTO new_id;

  RETURN new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION teisale.assign_task TO authenticated;


-- =============================================================================
-- 10. RPC ‧ EDI 送單(船務專屬,正式版需替換為實際 gateway 呼叫)
-- =============================================================================
CREATE OR REPLACE FUNCTION teisale.submit_edi(p_ship_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, teisale AS $$
DECLARE
  caller_tier text;
  v_customs_no text;
BEGIN
  caller_tier := teisale.my_tier();
  IF caller_tier <> 'shipping' THEN
    RAISE EXCEPTION '只有船務可送 EDI(目前 tier=%)', caller_tier;
  END IF;

  SELECT customs_no INTO v_customs_no FROM teisale.shipping_item WHERE id = p_ship_id;
  IF v_customs_no IS NULL OR v_customs_no = '' THEN
    RAISE EXCEPTION '請先填寫報單號碼(customs_no)再送 EDI';
  END IF;

  -- TODO: 此處應呼叫實際 EDI gateway(customs.tw / 物流商 API)
  -- 目前 stub 僅更新 status + timestamp
  UPDATE teisale.shipping_item
     SET edi_status = 'submitted',
         edi_synced_at = now()
   WHERE id = p_ship_id;
END;
$$;

GRANT EXECUTE ON FUNCTION teisale.submit_edi TO authenticated;


-- =============================================================================
-- 11. Seed:佔位 profile rows(本輪確認保留佔位)
--     真名上線時請替換以下 INSERT 的 name / email / ext
-- =============================================================================
-- 注意:profile 表通常由 auth.users 建立後 trigger 自動產生;
-- 若 ProjFlow 採此模式,以下 INSERT 應改為手動建 user 後 UPDATE profile。
-- 此處假設可直接 INSERT(若失敗請改 UPSERT 模式)。

INSERT INTO public.profiles (id, name, name_en, title, unit, ext, tier, emoji)
VALUES
  ('11111111-1111-1111-1111-000000000001', '林莉莉', 'Lily Lin',  '業務助理', '業務開發課 SD', '431', 'assistant', '🐰'),
  ('11111111-1111-1111-1111-000000000002', '楊咪雅', 'Mia Yang',  '業務助理', '業務開發課 SD', '432', 'assistant', '🦋'),
  ('22222222-2222-2222-2222-000000000001', '周船仔', 'Marco Chou', '船務',     '營運支援課 OPS', '441', 'shipping',  '🐳')
ON CONFLICT (id) DO NOTHING;


-- =============================================================================
-- 11.5 GRANT:Supabase 需明確授權 authenticated 角色,RLS 才會被評估
--      (未授權時所有存取會在 RLS 之前就被 permission denied 擋下)
-- =============================================================================
GRANT USAGE ON SCHEMA teisale TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON teisale.assistant_task TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON teisale.shipping_item  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON teisale.contact        TO authenticated;
GRANT SELECT ON teisale.v_company_overview TO authenticated;


-- =============================================================================
-- 12. 完成
-- =============================================================================
COMMIT;

-- ---------------- 自我驗證 ----------------
-- 執行後可用以下 query 確認:
--   SELECT * FROM teisale.v_company_overview;
--   SELECT count(*) FROM teisale.assistant_task;
--   SELECT count(*) FROM teisale.shipping_item;
--   SELECT count(*) FROM teisale.contact;
--   SELECT id, name, tier FROM public.profiles WHERE tier IN ('assistant','shipping');
