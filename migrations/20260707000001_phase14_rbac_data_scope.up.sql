-- Phase 14: RBAC & Data Isolation
-- 为 customers 和 leads 表增加 created_by 列（DataScope 行级过滤用）

ALTER TABLE customers ADD COLUMN created_by UUID;
CREATE INDEX idx_customers_tenant_created_by ON customers(tenant_id, created_by);

ALTER TABLE leads ADD COLUMN created_by UUID;
CREATE INDEX idx_leads_tenant_created_by ON leads(tenant_id, created_by);
