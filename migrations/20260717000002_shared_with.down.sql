DROP INDEX IF EXISTS idx_customers_shared_with;
DROP INDEX IF EXISTS idx_leads_shared_with;
ALTER TABLE customers DROP COLUMN IF EXISTS shared_with;
ALTER TABLE leads     DROP COLUMN IF EXISTS shared_with;
