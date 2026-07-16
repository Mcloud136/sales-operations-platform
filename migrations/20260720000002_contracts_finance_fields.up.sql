-- Task 5: 合同表单重写 — 新增财务字段，去除行项目依赖

-- 新增财务字段
ALTER TABLE contracts ADD COLUMN project_name     VARCHAR(255);
ALTER TABLE contracts ADD COLUMN amount            NUMERIC(15,2);
ALTER TABLE contracts ADD COLUMN payment_amount    NUMERIC(15,2);
ALTER TABLE contracts ADD COLUMN invoice_amount    NUMERIC(15,2);

-- 质保金字段
ALTER TABLE contracts ADD COLUMN warranty_period    VARCHAR(100);
ALTER TABLE contracts ADD COLUMN warranty_ratio     NUMERIC(5,2);
ALTER TABLE contracts ADD COLUMN warranty_amount    NUMERIC(15,2);
ALTER TABLE contracts ADD COLUMN warranty_guarantee BOOLEAN DEFAULT FALSE;

-- 成本/毛利
ALTER TABLE contracts ADD COLUMN cost_amount       NUMERIC(15,2);
ALTER TABLE contracts ADD COLUMN gross_profit      NUMERIC(15,2);
