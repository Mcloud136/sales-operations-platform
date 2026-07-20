-- 新增预计回款日期字段（用于合同列表"收款时间"列显示）
ALTER TABLE contracts ADD COLUMN expected_payment_at TIMESTAMPTZ;
