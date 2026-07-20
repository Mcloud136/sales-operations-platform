ALTER TABLE contracts ADD COLUMN status VARCHAR(50) NOT NULL DEFAULT 'Draft';
CREATE INDEX IF NOT EXISTS idx_contracts_tenant_status_assigned ON contracts(tenant_id, status, assigned_to);
