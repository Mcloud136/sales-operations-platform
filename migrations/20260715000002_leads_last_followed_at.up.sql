-- 为 leads 表添加 last_followed_at 列
-- 用于记录最近一次跟进时间，支持线索自动淘汰机制
ALTER TABLE leads ADD COLUMN IF NOT EXISTS last_followed_at TIMESTAMPTZ;

-- 初始化已有跟进记录的 last_followed_at
UPDATE leads SET last_followed_at = (
    SELECT MAX(created_at) FROM follow_ups WHERE follow_ups.lead_id = leads.id
) WHERE EXISTS (
    SELECT 1 FROM follow_ups WHERE follow_ups.lead_id = leads.id
);
