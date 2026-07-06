DROP INDEX IF EXISTS idx_users_manager;
DROP INDEX IF EXISTS idx_users_department;
DROP INDEX IF EXISTS idx_users_employee_id;
DROP INDEX IF EXISTS idx_users_phone;
DROP TRIGGER IF EXISTS trg_users_updated_at ON users;
DROP TABLE IF EXISTS users;
