-- Phase 10 Batch 0: Bids 回滚
-- 必须先删子表（bid_items），再删主表（bids），否则外键约束阻止删除

-- 移除已有表的 NOTIFY triggers
DROP TRIGGER IF EXISTS trg_customers_notify ON customers;
DROP TRIGGER IF EXISTS trg_leads_notify ON leads;
DROP TRIGGER IF EXISTS trg_contracts_notify ON contracts;

-- 删除 bid 表（含 triggers）
DROP TRIGGER IF EXISTS trg_bid_items_notify ON bid_items;
DROP TRIGGER IF EXISTS trg_bids_notify ON bids;
DROP TRIGGER IF EXISTS trg_bids_updated_at ON bids;

DROP TABLE IF EXISTS bid_items;
DROP TABLE IF EXISTS bids;

-- 删除通用 NOTIFY 函数
DROP FUNCTION IF EXISTS notify_changes();
