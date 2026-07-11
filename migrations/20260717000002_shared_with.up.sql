-- 分享功能：客户和线索的 shared_with 数组字段
-- shared_with 存储被分享人的 UUID 列表，配合 scope_filter 实现可见性共享

ALTER TABLE customers ADD COLUMN shared_with UUID[] NOT NULL DEFAULT '{}';
ALTER TABLE leads     ADD COLUMN shared_with UUID[] NOT NULL DEFAULT '{}';

CREATE INDEX idx_customers_shared_with ON customers USING GIN (shared_with);
CREATE INDEX idx_leads_shared_with     ON leads     USING GIN (shared_with);
