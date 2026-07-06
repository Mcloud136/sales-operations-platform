-- Phase 13 Batch 1: Follow-up History Tables
-- 跟进记录表 + 附件关联表

-- 1. 跟进记录表
CREATE TABLE follow_ups (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID        NOT NULL,
    lead_id      UUID        REFERENCES leads(id) ON DELETE CASCADE,
    customer_id  UUID        REFERENCES customers(id) ON DELETE CASCADE,
    type         VARCHAR(30) NOT NULL DEFAULT 'Note',
    content      TEXT        NOT NULL DEFAULT '',
    created_by   UUID        NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_follow_up_target CHECK (lead_id IS NOT NULL OR customer_id IS NOT NULL)
);

-- 2. 跟进附件关联表（多对多）
CREATE TABLE follow_up_attachments (
    follow_up_id UUID NOT NULL REFERENCES follow_ups(id) ON DELETE CASCADE,
    file_id      UUID NOT NULL,
    PRIMARY KEY (follow_up_id, file_id)
);

-- 3. 索引
CREATE INDEX idx_follow_ups_tenant_lead    ON follow_ups (tenant_id, lead_id);
CREATE INDEX idx_follow_ups_tenant_customer ON follow_ups (tenant_id, customer_id);
CREATE INDEX idx_follow_ups_created_by     ON follow_ups (created_by);
CREATE INDEX idx_follow_ups_created_at     ON follow_ups (tenant_id, created_at DESC);

-- 4. updated_at trigger
CREATE TRIGGER trg_follow_ups_updated_at
    BEFORE UPDATE ON follow_ups
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
