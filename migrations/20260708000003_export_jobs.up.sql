-- Phase 15: 异步导出任务表
-- 支持 CSV 报表异步导出，FOR UPDATE SKIP LOCKED 多实例安全

CREATE TABLE IF NOT EXISTS export_jobs (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID        NOT NULL,
    created_by      UUID        NOT NULL,
    export_type     VARCHAR(50) NOT NULL,     -- leads_csv / dashboard_summary / contracts_csv
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending/processing/completed/failed
    params          JSONB       NOT NULL DEFAULT '{}',
    total_rows      INT         NOT NULL DEFAULT 0,
    processed_rows  INT         NOT NULL DEFAULT 0,
    download_url    TEXT,
    error_message   TEXT,
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_export_jobs_updated_at BEFORE UPDATE ON export_jobs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_export_jobs_tenant_status ON export_jobs (tenant_id, status);
CREATE INDEX idx_export_jobs_pending ON export_jobs (status, created_at)
    WHERE status = 'pending';
