DROP INDEX IF EXISTS idx_customers_assigned_to;
ALTER TABLE customers DROP COLUMN IF EXISTS assigned_to;
