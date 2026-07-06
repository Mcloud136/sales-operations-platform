-- Casbin RBAC policy storage table (required by sqlx-adapter)
CREATE TABLE IF NOT EXISTS casbin_rule (
    id    SERIAL  PRIMARY KEY,
    ptype VARCHAR NOT NULL,
    v0    VARCHAR NOT NULL,
    v1    VARCHAR NOT NULL,
    v2    VARCHAR NOT NULL,
    v3    VARCHAR NOT NULL,
    v4    VARCHAR NOT NULL,
    v5    VARCHAR NOT NULL
);

CREATE INDEX idx_casbin_rule_ptype ON casbin_rule (ptype);
