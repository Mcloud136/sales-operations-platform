-- 客户管理字段结构化改造
-- 分区1: 基本信息扩展
-- 分区2: 联系信息
-- 分区3: 关键联系人（JSONB）

ALTER TABLE customers
    ADD COLUMN IF NOT EXISTS short_name      VARCHAR(100),
    ADD COLUMN IF NOT EXISTS customer_type   VARCHAR(50),
    ADD COLUMN IF NOT EXISTS company_size    VARCHAR(50),
    ADD COLUMN IF NOT EXISTS source          VARCHAR(50),
    ADD COLUMN IF NOT EXISTS level           VARCHAR(50),
    ADD COLUMN IF NOT EXISTS region_province VARCHAR(50),
    ADD COLUMN IF NOT EXISTS region_city     VARCHAR(50),
    ADD COLUMN IF NOT EXISTS region_district VARCHAR(50),
    ADD COLUMN IF NOT EXISTS address         VARCHAR(500),
    ADD COLUMN IF NOT EXISTS phone           VARCHAR(50),
    ADD COLUMN IF NOT EXISTS email           VARCHAR(255),
    ADD COLUMN IF NOT EXISTS contacts        JSONB NOT NULL DEFAULT '[]';
