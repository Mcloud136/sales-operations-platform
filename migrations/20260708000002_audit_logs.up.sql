-- Phase 15: 操作审计日志分区表
-- 按月分区，支持企业合规审计追踪

CREATE TABLE IF NOT EXISTS audit_logs (
    id              BIGSERIAL,
    tenant_id       UUID        NOT NULL,
    user_id         UUID        NOT NULL,
    action          VARCHAR(50) NOT NULL,
    resource_type   VARCHAR(50) NOT NULL,
    resource_id     UUID,
    old_value       JSONB,
    new_value       JSONB,
    ip_address      VARCHAR(45),
    user_agent      TEXT,
    request_path    VARCHAR(500),
    request_method  VARCHAR(10),
    status_code     SMALLINT,
    duration_ms     INT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- 初始分区（2026 年 7-9 月）
CREATE TABLE audit_logs_y2026m07 PARTITION OF audit_logs FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE audit_logs_y2026m08 PARTITION OF audit_logs FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE audit_logs_y2026m09 PARTITION OF audit_logs FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');

-- 索引
CREATE INDEX idx_audit_tenant_created ON audit_logs (tenant_id, created_at DESC);
CREATE INDEX idx_audit_resource ON audit_logs (resource_type, resource_id);
CREATE INDEX idx_audit_user ON audit_logs (tenant_id, user_id, created_at DESC);
