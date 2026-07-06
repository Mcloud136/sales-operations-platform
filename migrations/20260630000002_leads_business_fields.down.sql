-- Phase 5 Step 4: Leads Business Fields Migration (Rollback)

DROP INDEX IF EXISTS idx_leads_tenant_created;
DROP INDEX IF EXISTS idx_leads_tenant_status;

ALTER TABLE leads DROP COLUMN IF EXISTS converted_at;
ALTER TABLE leads DROP COLUMN IF EXISTS lost_reason;
ALTER TABLE leads DROP COLUMN IF EXISTS note;
ALTER TABLE leads DROP COLUMN IF EXISTS phone;
ALTER TABLE leads DROP COLUMN IF EXISTS email;
ALTER TABLE leads DROP COLUMN IF EXISTS contact_name;
ALTER TABLE leads DROP COLUMN IF EXISTS company_name;
ALTER TABLE leads DROP COLUMN IF EXISTS title;
