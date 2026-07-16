-- 合同验收提醒：新增预计验收日期字段
ALTER TABLE contracts ADD COLUMN expected_acceptance_at TIMESTAMPTZ;
