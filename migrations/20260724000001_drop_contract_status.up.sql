-- 移除合同状态机：status 列不再需要（审批流程简化）
ALTER TABLE contracts DROP COLUMN IF EXISTS status;

-- 移除依赖 status 的索引（如有）
DROP INDEX IF EXISTS idx_contracts_tenant_status_assigned;
