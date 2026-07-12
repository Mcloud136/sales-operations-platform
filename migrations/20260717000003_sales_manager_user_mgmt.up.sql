-- 补齐 sales_manager 对 admin/users 的 create/write 权限和 admin/roles 的 read 权限
-- 幂等：使用 ON CONFLICT DO NOTHING 防止重复插入

-- admin/users: create
INSERT INTO casbin_rule (ptype, v0, v1, v2, v3, v4, v5)
SELECT 'p', 'sales_manager', '*', 'admin/users', 'create', '', ''
WHERE NOT EXISTS (
  SELECT 1 FROM casbin_rule WHERE ptype='p' AND v0='sales_manager' AND v2='admin/users' AND v3='create'
);

-- admin/users: write
INSERT INTO casbin_rule (ptype, v0, v1, v2, v3, v4, v5)
SELECT 'p', 'sales_manager', '*', 'admin/users', 'write', '', ''
WHERE NOT EXISTS (
  SELECT 1 FROM casbin_rule WHERE ptype='p' AND v0='sales_manager' AND v2='admin/users' AND v3='write'
);

-- admin/roles: read
INSERT INTO casbin_rule (ptype, v0, v1, v2, v3, v4, v5)
SELECT 'p', 'sales_manager', '*', 'admin/roles', 'read', '', ''
WHERE NOT EXISTS (
  SELECT 1 FROM casbin_rule WHERE ptype='p' AND v0='sales_manager' AND v2='admin/roles' AND v3='read'
);
