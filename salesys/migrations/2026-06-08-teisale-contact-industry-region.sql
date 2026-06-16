-- =============================================================================
-- TEi-Salesys ‧ 聯絡簿擴充 — ProjFlow Migration
-- File:    2026-06-08-teisale-contact-industry-region.sql
-- Branch:  claude/fervent-ptolemy-zSq3U
-- Depends: 2026-05-28-teisale-assistant-shipping-contacts.sql (must run first)
-- Target:  ProjFlow PostgreSQL (Supabase-style auth.uid())
--
-- 本 migration 對應前端 teisale-prototype.html 聯絡簿頁的新功能:
--   1. 客戶 / 供應商 加上「產業別」分類(11 種)
--   2. 加上「區域 → 國家」層級分類(11 區 / 30+ 國家)
--   3. 增加索引以支援多維度篩選查詢
--
-- 對應前端常數:
--   INDUSTRY (見前端) — aero/auto/moto/cycle/ev/ind/med/def/marine/elec/other
--   REGIONS (見前端) — tw/ea/sea/sa/na/eu/oc/me/la/af/other
--
-- 本 migration 採 idempotent 策略,可重複執行。
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. ALTER TABLE teisale.contact 新增三個欄位
-- -----------------------------------------------------------------------------
ALTER TABLE teisale.contact
  ADD COLUMN IF NOT EXISTS industry text,
  ADD COLUMN IF NOT EXISTS region   text,
  ADD COLUMN IF NOT EXISTS country  text;

-- CHECK 約束(可選 — 採白名單方式,若以後新增類別需更新)
-- 採 IF NOT EXISTS 風格不可用於 CONSTRAINT,以 DO block 包覆
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contact_industry_chk') THEN
    ALTER TABLE teisale.contact ADD CONSTRAINT contact_industry_chk CHECK (
      industry IS NULL OR industry IN (
        'aero','auto','moto','cycle','ev','ind','med','def','marine','elec','other'
      )
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contact_region_chk') THEN
    ALTER TABLE teisale.contact ADD CONSTRAINT contact_region_chk CHECK (
      region IS NULL OR region IN (
        'tw','ea','sea','sa','na','eu','oc','me','la','af','other'
      )
    );
  END IF;
END $$;

-- 為三個新欄位加索引(僅索引非 NULL 值,節省空間)
CREATE INDEX IF NOT EXISTS idx_contact_industry ON teisale.contact(industry) WHERE industry IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_contact_region   ON teisale.contact(region)   WHERE region   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_contact_country  ON teisale.contact(country)  WHERE country  IS NOT NULL;

-- 複合索引(常用組合:同產業同區域的客戶清單)
CREATE INDEX IF NOT EXISTS idx_contact_industry_region
  ON teisale.contact(industry, region)
  WHERE industry IS NOT NULL AND region IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 2. 查詢輔助 view:依產業 / 區域 聚合
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW teisale.v_contact_by_industry AS
SELECT
  industry,
  COUNT(*)                                       AS total,
  COUNT(*) FILTER (WHERE kind = 'customer')      AS customers,
  COUNT(*) FILTER (WHERE kind = 'supplier')      AS suppliers
FROM teisale.contact
WHERE industry IS NOT NULL
GROUP BY industry
ORDER BY total DESC;

CREATE OR REPLACE VIEW teisale.v_contact_by_region AS
SELECT
  region,
  country,
  COUNT(*)                                       AS total,
  COUNT(*) FILTER (WHERE kind = 'customer')      AS customers,
  COUNT(*) FILTER (WHERE kind = 'supplier')      AS suppliers
FROM teisale.contact
WHERE region IS NOT NULL
GROUP BY region, country
ORDER BY region, country;


-- -----------------------------------------------------------------------------
-- 3. 更新 v_company_overview:加入分類統計欄位
-- -----------------------------------------------------------------------------
-- 重建 view (CREATE OR REPLACE VIEW 允許新增欄位)
CREATE OR REPLACE VIEW teisale.v_company_overview AS
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
  (SELECT count(*) FROM teisale.contact WHERE kind='supplier')                 AS contact_suppliers,
  -- 新增:分類覆蓋率(已分類的聯絡人比例)
  (SELECT count(*) FROM teisale.contact WHERE industry IS NOT NULL)            AS contact_with_industry,
  (SELECT count(*) FROM teisale.contact WHERE region IS NOT NULL)              AS contact_with_region,
  (SELECT count(DISTINCT industry) FROM teisale.contact WHERE industry IS NOT NULL) AS distinct_industries,
  (SELECT count(DISTINCT region)   FROM teisale.contact WHERE region IS NOT NULL)   AS distinct_regions,
  (SELECT count(DISTINCT country)  FROM teisale.contact WHERE country IS NOT NULL)  AS distinct_countries;


COMMIT;

-- ---------------- 驗證 ----------------
-- 執行後可用以下 query 確認:
--   \d teisale.contact
--   SELECT * FROM teisale.v_contact_by_industry;
--   SELECT * FROM teisale.v_contact_by_region;
--   SELECT * FROM teisale.v_company_overview;
