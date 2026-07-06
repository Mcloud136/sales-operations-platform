DROP TRIGGER IF EXISTS trg_export_jobs_updated_at ON export_jobs;
DROP INDEX IF EXISTS idx_export_jobs_pending;
DROP INDEX IF EXISTS idx_export_jobs_tenant_status;
DROP TABLE IF EXISTS export_jobs;
