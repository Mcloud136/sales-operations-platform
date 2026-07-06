-- Phase 9 Batch 0: Contracts 合约表 + ContractItems 行项目子表
--
-- 铁律 1：状态机防绕过 — status 字段仅通过 PATCH /contracts/{id}/status 变更
-- Phase 9 约束：金额字段 NUMERIC(15,2)，严禁 f64/i64 存分
-- total_amount 防篡改：由 contract_items.subtotal 求和推导，前端不直接传入

-- ═══════════════════════════════════════════════════════════════════
-- contracts 主表
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS contracts (
    id             UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      UUID           NOT NULL,
    contract_no    VARCHAR(32)    NOT NULL UNIQUE,
    title          VARCHAR(255)   NOT NULL DEFAULT '',
    status         VARCHAR(50)    NOT NULL DEFAULT 'Draft',
    total_amount   NUMERIC(15,2)  NOT NULL DEFAULT 0,
    currency       VARCHAR(10)    NOT NULL DEFAULT 'CNY',
    signed_at      TIMESTAMPTZ,
    customer_id    UUID           REFERENCES customers(id) ON DELETE SET NULL,
    lead_id        UUID           REFERENCES leads(id) ON DELETE SET NULL,
    assigned_to    UUID,
    created_by     UUID,
    created_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════════
-- contract_items 行项目明细子表（ON DELETE CASCADE）
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS contract_items (
    id             UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id    UUID           NOT NULL REFERENCES contracts(id) ON DELETE CASCADE,
    product_name   VARCHAR(255)   NOT NULL DEFAULT '',
    quantity       INTEGER        NOT NULL DEFAULT 1,
    unit_price     NUMERIC(15,2)  NOT NULL DEFAULT 0,
    subtotal       NUMERIC(15,2)  NOT NULL DEFAULT 0,
    created_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════════
-- 索引
-- ═══════════════════════════════════════════════════════════════════

-- 多租户隔离 + 状态过滤（基础索引）
CREATE INDEX IF NOT EXISTS idx_contracts_tenant_id
    ON contracts(tenant_id);

-- Dashboard 聚合核心索引：WHERE tenant_id = $1 AND status = $2 AND assigned_to = $3
CREATE INDEX IF NOT EXISTS idx_contracts_tenant_status_assigned
    ON contracts(tenant_id, status, assigned_to);

-- 多租户时间排序（分页查询）
CREATE INDEX IF NOT EXISTS idx_contracts_tenant_created
    ON contracts(tenant_id, created_at DESC);

-- 客户关联查询
CREATE INDEX IF NOT EXISTS idx_contracts_customer_id
    ON contracts(customer_id);

-- 负责人过滤（sales Data Scope）
CREATE INDEX IF NOT EXISTS idx_contracts_assigned_to
    ON contracts(assigned_to);

-- contract_items 按 contract_id 查询（加载行项目明细）
CREATE INDEX IF NOT EXISTS idx_contract_items_contract_id
    ON contract_items(contract_id);

-- ═══════════════════════════════════════════════════════════════════
-- Trigger: updated_at 自动更新
-- ═══════════════════════════════════════════════════════════════════

-- 复用已有 set_updated_at() 函数
CREATE TRIGGER trg_contracts_updated_at
    BEFORE UPDATE ON contracts
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
