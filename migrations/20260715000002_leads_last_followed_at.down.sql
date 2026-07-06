-- 回滚：移除 leads.last_followed_at 列
ALTER TABLE leads DROP COLUMN IF EXISTS last_followed_at;
