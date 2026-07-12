-- 回滚：移除 sales_manager 对 admin/users 的 create/write 和 admin/roles 的 read
DELETE FROM casbin_rule WHERE ptype='p' AND v0='sales_manager' AND v2='admin/users' AND v3 IN ('create', 'write');
DELETE FROM casbin_rule WHERE ptype='p' AND v0='sales_manager' AND v2='admin/roles' AND v3='read';
