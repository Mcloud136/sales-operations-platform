-- Phase 14 rollback: 移除 created_by 列

DROP INDEX IF EXISTS idx_leads_tenant_created_by;
ALTER TABLE leads DROP COLUMN IF EXISTS created_by;

DROP INDEX IF EXISTS idx_customers_tenant_created_by;
ALTER TABLE customers DROP COLUMN IF EXISTS created_by;
