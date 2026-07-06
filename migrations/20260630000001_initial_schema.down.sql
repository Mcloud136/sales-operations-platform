-- Revert Phase 2 Task A: Core CRM Domain Schema
DROP TRIGGER IF EXISTS trg_leads_updated_at ON leads;
DROP TRIGGER IF EXISTS trg_customers_updated_at ON customers;
DROP FUNCTION IF EXISTS set_updated_at();
DROP TABLE IF EXISTS leads;
DROP TABLE IF EXISTS customers;
