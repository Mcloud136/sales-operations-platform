-- Phase 22: FollowUp 聚合查询索引
-- 支持租户级时间范围+类型筛选的聚合查询

-- 1. 租户级聚合查询索引（替代全表扫描）
CREATE INDEX IF NOT EXISTS idx_follow_ups_tenant_created_desc
    ON follow_ups (tenant_id, created_at DESC);

-- 2. 按类型筛选索引
CREATE INDEX IF NOT EXISTS idx_follow_ups_tenant_type
    ON follow_ups (tenant_id, type);

-- 3. 按创建人筛选索引（团队跟进总览）
CREATE INDEX IF NOT EXISTS idx_follow_ups_tenant_created_by
    ON follow_ups (tenant_id, created_by, created_at DESC);
