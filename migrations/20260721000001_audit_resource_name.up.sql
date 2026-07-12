-- 添加 resource_name 列，记录操作资源的显示名称（如客户名称、线索标题等）
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS resource_name VARCHAR(200);

-- 为已有记录回填 resource_name（从 new_value / old_value JSON 中提取）
UPDATE audit_logs
SET resource_name = COALESCE(
    new_value->>'title',
    new_value->>'name',
    new_value->>'company_name',
    new_value->>'contract_no',
    new_value->>'bid_no',
    LEFT(new_value->>'content', 200),
    old_value->>'title',
    old_value->>'name',
    old_value->>'company_name',
    old_value->>'contract_no',
    old_value->>'bid_no',
    LEFT(old_value->>'content', 200)
)
WHERE resource_name IS NULL
  AND (new_value IS NOT NULL OR old_value IS NOT NULL);
