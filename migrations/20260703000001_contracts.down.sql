-- Phase 9 Batch 0: Contracts 回滚
-- 必须先删子表（contract_items），再删主表（contracts），否则外键约束阻止删除
DROP TABLE IF EXISTS contract_items;
DROP TABLE IF EXISTS contracts;
