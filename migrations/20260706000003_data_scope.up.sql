-- Phase 13 Batch 1: Data Scope (数据范围权限) Table
-- 用户数据范围配置（Self/Team/All）

CREATE TABLE user_data_scopes (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID        NOT NULL,
    user_id      UUID        NOT NULL,
    scope        VARCHAR(20) NOT NULL DEFAULT 'Self',
    team_members UUID[]      NOT NULL DEFAULT '{}',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_tenant_user UNIQUE (tenant_id, user_id)
);

CREATE INDEX idx_data_scopes_tenant ON user_data_scopes (tenant_id);

-- updated_at trigger
CREATE TRIGGER trg_user_data_scopes_updated_at
    BEFORE UPDATE ON user_data_scopes
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
