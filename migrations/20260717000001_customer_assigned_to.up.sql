-- 客户负责人字段：支持数据范围过滤（assigned_to + created_by 双字段）
ALTER TABLE customers ADD COLUMN assigned_to UUID;
CREATE INDEX idx_customers_assigned_to ON customers(assigned_to);
