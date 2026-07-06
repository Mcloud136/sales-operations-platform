-- Phase 6: Refresh Token 持久化表
-- 存储 Refresh Token 的 SHA-256 hash（不存明文），支持 Token 旋转策略
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID        NOT NULL,
    user_id     UUID        NOT NULL,
    token_hash  TEXT        NOT NULL,          -- SHA-256(refresh_token)
    expires_at  TIMESTAMPTZ NOT NULL,          -- 服务端过期时间
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- hash 索引：refresh 时通过 hash 快速查找
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_hash ON refresh_tokens(token_hash);
-- 租户索引：支持按租户批量清理过期 Token
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_tenant ON refresh_tokens(tenant_id);
-- 过期清理索引：定时任务清理已过期 Token
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_expires ON refresh_tokens(expires_at);
