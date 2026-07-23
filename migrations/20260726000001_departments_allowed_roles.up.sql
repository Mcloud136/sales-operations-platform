-- 部门-角色绑定：为 departments 表增加 allowed_roles 列
-- TEXT[] 存储允许的角色列表；空数组 '{}' 表示"未配置"（回退旧行为）
ALTER TABLE departments
    ADD COLUMN IF NOT EXISTS allowed_roles TEXT[] NOT NULL DEFAULT '{}';

COMMENT ON COLUMN departments.allowed_roles IS
    '该部门允许分配的角色列表，空数组表示未配置（不限制）';
