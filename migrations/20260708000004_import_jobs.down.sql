DROP TRIGGER IF EXISTS trg_import_jobs_updated_at ON import_jobs;
DROP INDEX IF EXISTS idx_import_jobs_pending;
DROP INDEX IF EXISTS idx_import_jobs_tenant_status;
DROP TABLE IF EXISTS import_jobs;
