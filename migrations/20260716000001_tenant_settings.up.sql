-- tenant_settings 表：租户级品牌配置（P1: 品牌设置基础版）
CREATE TABLE IF NOT EXISTS tenant_settings (
    tenant_id    UUID PRIMARY KEY,
    company_name VARCHAR(200) NOT NULL DEFAULT '',
    logo_file_id UUID,  -- FK → files(id)，可空（无 Logo）
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
