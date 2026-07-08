-- Revert role "sales_manager" → "manager" in Casbin policies
UPDATE casbin_rule SET v0 = 'manager' WHERE ptype = 'p' AND v0 = 'sales_manager';
UPDATE casbin_rule SET v1 = 'manager' WHERE ptype = 'g' AND v1 = 'sales_manager';
