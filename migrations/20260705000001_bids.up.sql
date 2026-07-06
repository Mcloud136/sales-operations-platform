-- Phase 10 Batch 0: Bids 标书表 + BidItems 行项目子表
--
-- 铁律 1：状态机防绕过 — status 字段仅通过 PATCH /bids/{id}/status 变更
-- Phase 9 约束：金额字段 NUMERIC(15,2)，严禁 f64/i64 存分
-- total_amount 防篡改：由 bid_items.subtotal 求和推导，前端不直接传入
--
-- 补丁 #1：convert_to_contract 跨表事务锁顺序铁律
--   SELECT bids ... FOR UPDATE → INSERT contracts → UPDATE bids
-- 补丁 #2：NOTIFY trigger 使用 FOR EACH STATEMENT（非 FOR EACH ROW）
--   批量操作天然去重，避免 mpsc channel 溢出

-- ═══════════════════════════════════════════════════════════════════
-- notify_changes() 通用 NOTIFY 触发器函数
-- ═══════════════════════════════════════════════════════════════════
--
-- 使用 FOR EACH STATEMENT 挂载，批量操作仅触发 1 次 NOTIFY。
-- pg_notify() 内置 8000 字节 payload 上限防御（EXCEPTION 捕获）。

CREATE OR REPLACE FUNCTION notify_changes()
RETURNS TRIGGER AS $$
DECLARE
    ch TEXT;
    payload TEXT;
BEGIN
    -- 通道命名约定：crm_{table_name}_changes（与 constants.rs ALL_NOTIFY_CHANNELS 对齐）
    ch := 'crm_' || TG_TABLE_NAME || '_changes';
    payload := json_build_object(
        'op', TG_OP,
        'table', TG_TABLE_NAME
    )::text;

    -- pg_notify 8000 字节 payload 上限防御
    BEGIN
        PERFORM pg_notify(ch, payload);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg_notify failed on channel %: %', ch, SQLERRM;
    END;

    RETURN NULL; -- FOR EACH STATEMENT 触发器返回值被忽略
END;
$$ LANGUAGE plpgsql;

-- ═══════════════════════════════════════════════════════════════════
-- bids 主表
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS bids (
    id             UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      UUID           NOT NULL,
    bid_no         VARCHAR(32)    NOT NULL UNIQUE,
    title          VARCHAR(255)   NOT NULL DEFAULT '',
    status         VARCHAR(50)    NOT NULL DEFAULT 'Draft',
    total_amount   NUMERIC(15,2)  NOT NULL DEFAULT 0,
    currency       VARCHAR(10)    NOT NULL DEFAULT 'CNY',
    deadline       TIMESTAMPTZ,
    submitted_at   TIMESTAMPTZ,
    customer_id    UUID           REFERENCES customers(id) ON DELETE SET NULL,
    lead_id        UUID           REFERENCES leads(id) ON DELETE SET NULL,
    contract_id    UUID           UNIQUE REFERENCES contracts(id) ON DELETE SET NULL,
    assigned_to    UUID,
    created_by     UUID,
    lost_reason    TEXT,
    created_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════════
-- bid_items 行项目明细子表（ON DELETE CASCADE）
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS bid_items (
    id             UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
    bid_id         UUID           NOT NULL REFERENCES bids(id) ON DELETE CASCADE,
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
CREATE INDEX IF NOT EXISTS idx_bids_tenant_id
    ON bids(tenant_id);

-- Dashboard 聚合核心索引：WHERE tenant_id = $1 AND status = $2 AND assigned_to = $3
CREATE INDEX IF NOT EXISTS idx_bids_tenant_status_assigned
    ON bids(tenant_id, status, assigned_to);

-- 多租户时间排序（分页查询）
CREATE INDEX IF NOT EXISTS idx_bids_tenant_created
    ON bids(tenant_id, created_at DESC);

-- 客户关联查询
CREATE INDEX IF NOT EXISTS idx_bids_customer_id
    ON bids(customer_id);

-- 负责人过滤（sales Data Scope）
CREATE INDEX IF NOT EXISTS idx_bids_assigned_to
    ON bids(assigned_to);

-- bid_items 按 bid_id 查询（加载行项目明细）
CREATE INDEX IF NOT EXISTS idx_bid_items_bid_id
    ON bid_items(bid_id);

-- ═══════════════════════════════════════════════════════════════════
-- Trigger: updated_at 自动更新
-- ═══════════════════════════════════════════════════════════════════

-- 复用已有 set_updated_at() 函数
CREATE TRIGGER trg_bids_updated_at
    BEFORE UPDATE ON bids
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- ═══════════════════════════════════════════════════════════════════
-- NOTIFY Trigger（FOR EACH STATEMENT — 补丁 #2 去重策略）
-- ═══════════════════════════════════════════════════════════════════
--
-- FOR EACH STATEMENT：批量 INSERT/UPDATE/DELETE 仅触发 1 次 NOTIFY，
-- 天然去重，避免 1024-cap mpsc channel 溢出。

CREATE TRIGGER trg_bids_notify
    AFTER INSERT OR UPDATE OR DELETE ON bids
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_changes();

CREATE TRIGGER trg_bid_items_notify
    AFTER INSERT OR UPDATE OR DELETE ON bid_items
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_changes();

-- ═══════════════════════════════════════════════════════════════════
-- 为已有表补加 NOTIFY Trigger（contracts / leads / customers）
-- ═══════════════════════════════════════════════════════════════════

CREATE TRIGGER trg_contracts_notify
    AFTER INSERT OR UPDATE OR DELETE ON contracts
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_changes();

CREATE TRIGGER trg_leads_notify
    AFTER INSERT OR UPDATE OR DELETE ON leads
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_changes();

CREATE TRIGGER trg_customers_notify
    AFTER INSERT OR UPDATE OR DELETE ON customers
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_changes();
