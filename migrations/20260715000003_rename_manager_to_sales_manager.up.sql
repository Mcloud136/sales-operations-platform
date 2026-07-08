-- Rename role "manager" → "sales_manager" in Casbin policies
-- p-type policies: v0 is the role name
UPDATE casbin_rule SET v0 = 'sales_manager' WHERE ptype = 'p' AND v0 = 'manager';
-- g-type policies: v1 is the role name
UPDATE casbin_rule SET v1 = 'sales_manager' WHERE ptype = 'g' AND v1 = 'manager';
