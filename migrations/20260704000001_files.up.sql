-- Phase 9 Batch 3: Files 文件管理表
--
-- 状态机：Pending -> Confirmed（单向，不可逆）
-- 孤儿文件定义：status = 'Pending' AND created_at < NOW() - INTERVAL '24 hours'
-- S3 Key 格式：{tenant_id}/{uuid}/{original_filename}

CREATE TABLE IF NOT EXISTS files (
    id          UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID           NOT NULL,
    file_name   VARCHAR(512)   NOT NULL,
    s3_key      VARCHAR(1024)  NOT NULL UNIQUE,
    mime_type   VARCHAR(128)   NOT NULL DEFAULT 'application/octet-stream',
    size_bytes  BIGINT         NOT NULL DEFAULT 0,
    status      VARCHAR(20)    NOT NULL DEFAULT 'Pending',
    created_by  UUID,
    created_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- 多租户隔离基础索引
CREATE INDEX IF NOT EXISTS idx_files_tenant_id ON files(tenant_id);

-- 孤儿文件扫描核心索引（status + created_at 复合）
CREATE INDEX IF NOT EXISTS idx_files_status_created ON files(status, created_at);

-- 按租户分页查询（预留）
CREATE INDEX IF NOT EXISTS idx_files_tenant_created ON files(tenant_id, created_at DESC);

-- updated_at 自动更新 trigger（复用已有 set_updated_at() 函数）
CREATE TRIGGER trg_files_updated_at
    BEFORE UPDATE ON files
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
