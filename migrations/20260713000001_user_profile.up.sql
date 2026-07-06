-- Phase 20 Task J: 企业级用户档案模型
-- 首先创建 users 基础表（项目此前无 users 表）
CREATE TABLE IF NOT EXISTS users (
    id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID         NOT NULL,
    username        VARCHAR(100) NOT NULL,
    name            VARCHAR(255) NOT NULL,
    email           VARCHAR(255) NOT NULL DEFAULT '',
    password_hash   TEXT         NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_users_tenant_username ON users(tenant_id, username);
CREATE INDEX idx_users_tenant ON users(tenant_id);

-- 企业级档案扩充字段
ALTER TABLE users ADD COLUMN department_id UUID REFERENCES departments(id);
ALTER TABLE users ADD COLUMN phone VARCHAR(20) NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN title VARCHAR(100) NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN employee_id VARCHAR(50) NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN manager_id UUID REFERENCES users(id);
ALTER TABLE users ADD COLUMN force_password_reset BOOLEAN NOT NULL DEFAULT true;

-- 唯一约束：同租户内手机号和工号唯一
CREATE UNIQUE INDEX idx_users_phone ON users(tenant_id, phone) WHERE phone != '';
CREATE UNIQUE INDEX idx_users_employee_id ON users(tenant_id, employee_id) WHERE employee_id != '';
CREATE INDEX idx_users_department ON users(department_id);
CREATE INDEX idx_users_manager ON users(manager_id);

-- updated_at trigger
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
