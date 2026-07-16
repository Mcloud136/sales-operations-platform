-- 通知中心表
CREATE TABLE IF NOT EXISTS notifications (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID        NOT NULL,
    user_id         UUID        NOT NULL,
    type            VARCHAR(50) NOT NULL,
    title           VARCHAR(255) NOT NULL,
    content         TEXT,
    is_read         BOOLEAN     NOT NULL DEFAULT FALSE,
    resource_type   VARCHAR(50),
    resource_id     UUID,
    trigger_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at         TIMESTAMPTZ
);

-- 用户未读通知查询索引
CREATE INDEX idx_notifications_user_unread ON notifications (tenant_id, user_id, is_read, created_at DESC);
-- 定时通知扫描索引
CREATE INDEX idx_notifications_trigger ON notifications (trigger_at) WHERE trigger_at IS NOT NULL AND is_read = FALSE;
