-- Phase 15: 异步导入任务表
-- 支持 CSV 批量导入，导入前配额预检

CREATE TABLE IF NOT EXISTS import_jobs (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID        NOT NULL,
    created_by      UUID        NOT NULL,
    import_type     VARCHAR(50) NOT NULL,     -- leads_csv
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending/processing/completed/failed
    source_file_key TEXT        NOT NULL,     -- S3 文件 Key
    total_rows      INT         NOT NULL DEFAULT 0,
    processed_rows  INT         NOT NULL DEFAULT 0,
    success_rows    INT         NOT NULL DEFAULT 0,
    failed_rows     INT         NOT NULL DEFAULT 0,
    error_report    JSONB,
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_import_jobs_updated_at BEFORE UPDATE ON import_jobs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_import_jobs_tenant_status ON import_jobs (tenant_id, status);
CREATE INDEX idx_import_jobs_pending ON import_jobs (status, created_at)
    WHERE status = 'pending';
