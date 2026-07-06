-- Phase 5 Step 4: Leads Business Fields Migration
-- 新增 8 个业务字段 + 回填 title + 2 个复合索引

-- 1. 新增业务字段
ALTER TABLE leads ADD COLUMN IF NOT EXISTS title          VARCHAR(255)   NOT NULL DEFAULT '';
ALTER TABLE leads ADD COLUMN IF NOT EXISTS company_name   VARCHAR(255);
ALTER TABLE leads ADD COLUMN IF NOT EXISTS contact_name   VARCHAR(100);
ALTER TABLE leads ADD COLUMN IF NOT EXISTS email          VARCHAR(255);
ALTER TABLE leads ADD COLUMN IF NOT EXISTS phone          VARCHAR(50);
ALTER TABLE leads ADD COLUMN IF NOT EXISTS note           TEXT;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS lost_reason    VARCHAR(255);
ALTER TABLE leads ADD COLUMN IF NOT EXISTS converted_at   TIMESTAMPTZ;

-- 2. 回填已有记录的 title（使用前 8 位 UUID 作为默认标题）
UPDATE leads SET title = 'Lead-' || substring(id::text, 1, 8)
WHERE title = '';

-- 3. 新增复合索引（优化多租户查询）
CREATE INDEX IF NOT EXISTS idx_leads_tenant_status  ON leads (tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_leads_tenant_created ON leads (tenant_id, created_at DESC);
