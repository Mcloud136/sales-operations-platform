#!/usr/bin/env bash
# Sales Operations Platform — First-Time Setup Script
# Target: Ubuntu 26.04 LTS (clean install)
# Usage: sudo bash setup.sh
#
# This script installs all dependencies and deploys the application from scratch.
# For subsequent updates, use scripts/deploy.sh instead.
set -euo pipefail

DEPLOY_DIR="/opt/sales-ops"
SERVICE_USER="sales-ops"
GITEE_REPO="https://gitee.com/wxbns/sales-operations-platform.git"
GITHUB_REPO="https://github.com/Mcloud136/sales-operations-platform.git"

# ── Configurable defaults (override with environment variables) ──
DB_PASSWORD="${DB_PASSWORD:-CHANGE_ME_STRONG_PASSWORD}"
DB_USER="${DB_USER:-sales_ops}"
DB_NAME="${DB_NAME:-sales_ops}"
HTTPS_PORT="${HTTPS_PORT:-8089}"
HTTP_PORT="${HTTP_PORT:-8088}"
BACKEND_PORT="${BACKEND_PORT:-3000}"

echo "============================================="
echo "  Sales Operations Platform — First-Time Setup"
echo "============================================="
echo "  Deploy dir:    $DEPLOY_DIR"
echo "  HTTPS port:    $HTTPS_PORT"
echo "  HTTP port:     $HTTP_PORT (redirect)"
echo "  Backend port:  $BACKEND_PORT"
echo "============================================="
echo ""

# ── Step 1: System update + basic tools ─────────────────────────
echo "[1/9] System update and basic tools..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt upgrade -y -qq
apt install -y -qq curl wget gnupg lsb-release ca-certificates git nginx openssl
echo "  Done."

# ── Step 2: PostgreSQL 18 ────────────────────────────────────────
echo "[2/9] Installing PostgreSQL 18..."
if command -v psql &>/dev/null && psql --version | grep -q "18"; then
    echo "  PostgreSQL 18 already installed, skipping."
else
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
    apt update -qq
    apt install -y -qq postgresql-18 postgresql-contrib-18
    echo "  PostgreSQL 18 installed."
fi
systemctl enable --now postgresql

# Create database and user
if sudo -u postgres psql -t -c "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    echo "  Database user '$DB_USER' already exists."
else
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    echo "  Database user '$DB_USER' created."
fi
if sudo -u postgres psql -t -c "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    echo "  Database '$DB_NAME' already exists."
else
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
    echo "  Database '$DB_NAME' created."
fi

# Configure pg_hba.conf for password auth
PG_HBA=$(sudo -u postgres psql -t -c "SHOW hba_file;" | tr -d ' ')
if ! grep -q "scram-sha-256" "$PG_HBA" 2>/dev/null; then
    sed -i "1i host    $DB_NAME    $DB_NAME    127.0.0.1/32    scram-sha-256" "$PG_HBA"
    sed -i "1i host    $DB_NAME    $DB_NAME    ::1/128         scram-sha-256" "$PG_HBA"
    sudo -u postgres psql -c "SELECT pg_reload_conf();"
    echo "  pg_hba.conf configured for password auth."
fi

# ── Step 3: Valkey 9.1 ───────────────────────────────────────────
echo "[3/9] Installing Valkey 9.1..."
if command -v valkey-server &>/dev/null; then
    echo "  Valkey already installed, skipping."
else
    VALKEY_VERSION="9.1.0"
    curl -sSL "https://github.com/valkey-io/valkey/releases/download/valkey-${VALKEY_VERSION}/valkey-${VALKEY_VERSION}-noble-x86_64.tar.gz" \
        -o /tmp/valkey.tar.gz || \
    curl -sSL "https://download.valkey.io/releases/valkey-${VALKEY_VERSION}-noble-x86_64.tar.gz" \
        -o /tmp/valkey.tar.gz
    tar xzf /tmp/valkey.tar.gz -C /tmp
    cp /tmp/valkey-${VALKEY_VERSION}-noble-x86_64/bin/* /usr/local/bin/
    rm -rf /tmp/valkey*
    echo "  Valkey $(valkey-server --version) installed."
fi

# Create valkey user, config, and systemd service
useradd -r -s /bin/false valkey 2>/dev/null || true
mkdir -p /etc/valkey /var/lib/valkey /var/log/valkey
chown valkey:valkey /var/lib/valkey /var/log/valkey

cat > /etc/valkey/valkey.conf << 'VALEOF'
bind 127.0.0.1 ::1
port 6379
daemonize no
dir /var/lib/valkey
logfile /var/log/valkey/valkey.log
maxmemory 256mb
maxmemory-policy allkeys-lru
VALEOF

cat > /etc/systemd/system/valkey-server.service << 'SVCEOF'
[Unit]
Description=Valkey In-Memory Data Store
After=network.target

[Service]
Type=simple
User=valkey
Group=valkey
ExecStart=/usr/local/bin/valkey-server /etc/valkey/valkey.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now valkey-server
echo "  Valkey service started."

# ── Step 4: SeaweedFS ────────────────────────────────────────────
echo "[4/9] Installing SeaweedFS..."
if command -v weed &>/dev/null; then
    echo "  SeaweedFS already installed, skipping."
else
    WEED_VERSION="3.80"
    curl -sSL "https://github.com/seaweedfs/seaweedfs/releases/download/${WEED_VERSION}/linux_amd64.tar.gz" \
        -o /tmp/weed.tar.gz
    tar xzf /tmp/weed.tar.gz -C /tmp
    cp /tmp/weed /usr/local/bin/
    chmod +x /usr/local/bin/weed
    rm -f /tmp/weed /tmp/weed.tar.gz
    echo "  SeaweedFS $(weed version 2>/dev/null | head -1) installed."
fi

mkdir -p /var/lib/seaweedfs/{master,volume,filer} /var/log/seaweedfs /etc/seaweedfs

# S5: 随机生成 SeaweedFS S3 Secret Key（避免硬编码弱密钥）
S3_SECRET_KEY=$(openssl rand -hex 32)
S3_ACCESS_KEY="sales_ops_access_key"

# S3 gateway config
cat > /etc/seaweedfs/s3.json << S3EOF
{
  "identities": [
    {
      "name": "sales_ops",
      "credentials": [
        { "accessKey": "${S3_ACCESS_KEY}", "secretKey": "${S3_SECRET_KEY}" }
      ],
      "actions": ["Admin", "Read", "Write", "List"]
    }
  ]
}
S3EOF
chmod 600 /etc/seaweedfs/s3.json
echo "  SeaweedFS S3 secret key generated and written to /etc/seaweedfs/s3.json"

# SeaweedFS systemd services
cat > /etc/systemd/system/seaweedfs-master.service << 'EOF'
[Unit]
Description=SeaweedFS Master
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/weed master -ip=127.0.0.1 -port=9333 -defaultReplication=000 -mdir=/var/lib/seaweedfs/master -volumeSizeLimitMB=1024
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=seaweedfs-master
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/seaweedfs-volume.service << 'EOF'
[Unit]
Description=SeaweedFS Volume
After=network.target seaweedfs-master.service
Requires=seaweedfs-master.service
[Service]
Type=simple
ExecStart=/usr/local/bin/weed volume -ip=127.0.0.1 -port=8080 -mserver=127.0.0.1:9333 -dir=/var/lib/seaweedfs/volume -max=100
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=seaweedfs-volume
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/seaweedfs-filer.service << 'EOF'
[Unit]
Description=SeaweedFS Filer
After=network.target seaweedfs-volume.service
Requires=seaweedfs-volume.service
[Service]
Type=simple
ExecStart=/usr/local/bin/weed filer -ip=127.0.0.1 -port=8888 -master=127.0.0.1:9333
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=seaweedfs-filer
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/seaweedfs-s3.service << 'EOF'
[Unit]
Description=SeaweedFS S3 Gateway
After=network.target seaweedfs-filer.service
Requires=seaweedfs-filer.service
[Service]
Type=simple
ExecStart=/usr/local/bin/weed s3 -port=8333 -filer=127.0.0.1:8888 -config=/etc/seaweedfs/s3.json
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=seaweedfs-s3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now seaweedfs-master
sleep 2
systemctl enable --now seaweedfs-volume
sleep 1
systemctl enable --now seaweedfs-filer
sleep 1
systemctl enable --now seaweedfs-s3
echo "  SeaweedFS services started."

# ── Step 5: SSL certificate (self-signed, 10-year) ───────────────
echo "[5/9] Generating self-signed SSL certificate..."
mkdir -p /etc/ssl/sales-ops
if [ -f /etc/ssl/sales-ops/server.crt ]; then
    echo "  SSL certificate already exists, skipping."
else
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout /etc/ssl/sales-ops/server.key \
        -out /etc/ssl/sales-ops/server.crt \
        -subj "/CN=sales-ops" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
    echo "  SSL certificate generated (10-year validity)."
fi

# ── Step 6: Clone distribution repo ──────────────────────────────
echo "[6/9] Cloning distribution repo..."
if [ -d "$DEPLOY_DIR/.git" ]; then
    echo "  Already cloned, pulling latest..."
    cd "$DEPLOY_DIR" && git pull origin main || true
else
    mkdir -p "$DEPLOY_DIR"
    git clone "$GITEE_REPO" "$DEPLOY_DIR" 2>/dev/null || \
    git clone "$GITHUB_REPO" "$DEPLOY_DIR"
    git -C "$DEPLOY_DIR" remote add github "$GITHUB_REPO" 2>/dev/null || true
fi

# Fix CRLF
find "$DEPLOY_DIR" -type f \( -name "*.env" -o -name "*.sh" -o -name "*.conf" \) \
    -exec sed -i 's/\r$//' {} \; 2>/dev/null || true

# ── Step 7: Configure environment ────────────────────────────────
echo "[7/9] Configuring environment..."
mkdir -p "$DEPLOY_DIR/config" "$DEPLOY_DIR/logs"

if [ ! -f "$DEPLOY_DIR/config/.env" ]; then
    cp "$DEPLOY_DIR/config/.env.production" "$DEPLOY_DIR/config/.env"

    # S4: 随机生成种子管理员密码（避免硬编码弱密码 admin@123）
    SEED_ADMIN_PASSWORD=$(openssl rand -base64 16)

    # Replace placeholders
    JWT_SECRET=$(openssl rand -hex 64)
    sed -i "s|CHANGE_ME_STRONG_PASSWORD|${DB_PASSWORD}|g" "$DEPLOY_DIR/config/.env"
    # S5: 同步 SeaweedFS S3 Secret Key 到 .env
    sed -i "s|CHANGE_ME_STRONG_SECRET_KEY|${S3_SECRET_KEY}|g" "$DEPLOY_DIR/config/.env"
    sed -i "s|CHANGE_ME_GENERATE_WITH_openssl_rand_hex_64|${JWT_SECRET}|g" "$DEPLOY_DIR/config/.env"
    # S4: 写入随机生成的种子管理员密码
    sed -i "s|^# SEED_ADMIN_PASSWORD=.*|SEED_ADMIN_PASSWORD=${SEED_ADMIN_PASSWORD}|g" "$DEPLOY_DIR/config/.env"
    chmod 600 "$DEPLOY_DIR/config/.env"

    # Set CORS_ORIGIN to actual server IP
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    sed -i "s|CORS_ORIGIN=https://localhost:${HTTPS_PORT}|CORS_ORIGIN=https://${SERVER_IP}:${HTTPS_PORT}|g" \
        "$DEPLOY_DIR/config/.env"

    echo "  .env configured."
else
    # 已存在 .env 时，从其中读取 SEED_ADMIN_PASSWORD 用于最终提示
    SEED_ADMIN_PASSWORD=$(grep -E '^SEED_ADMIN_PASSWORD=' "$DEPLOY_DIR/config/.env" | head -n1 | cut -d'=' -f2- || true)
    echo "  .env already exists, skipping."
fi

# ── Step 8: Create user + install systemd ─────────────────────────
echo "[8/9] Creating service user and installing systemd..."
useradd -r -m -s /bin/bash "$SERVICE_USER" 2>/dev/null || true
chown -R "$SERVICE_USER:$SERVICE_USER" "$DEPLOY_DIR"
chmod +x "$DEPLOY_DIR/backend/sales-operations-platform" 2>/dev/null || true

# Install sales-ops systemd service
cat > /etc/systemd/system/sales-ops.service << SVCEOF
[Unit]
Description=Sales Operations Platform Backend
After=network.target postgresql.service valkey-server.service
Wants=postgresql.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${DEPLOY_DIR}
ExecStart=${DEPLOY_DIR}/backend/sales-operations-platform
EnvironmentFile=${DEPLOY_DIR}/config/.env
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sales-ops
LimitNOFILE=65536
KillSignal=SIGTERM
TimeoutStopSec=30
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${DEPLOY_DIR}/logs
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SVCEOF

# Install Nginx config (Ubuntu 26.04 uses conf.d/)
cp "$DEPLOY_DIR/config/sales-ops.conf" /etc/nginx/conf.d/sales-ops.conf 2>/dev/null || true
# Also install to sites-available for older systems
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
cp "$DEPLOY_DIR/config/sales-ops.conf" /etc/nginx/sites-available/sales-ops.conf 2>/dev/null || true
ln -sf /etc/nginx/sites-available/sales-ops.conf /etc/nginx/sites-enabled/sales-ops.conf 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

systemctl daemon-reload
systemctl enable sales-ops
echo "  Systemd services installed."

# ── Step 9: Start services + health check ─────────────────────────
echo "[9/9] Starting services..."
nginx -t && systemctl restart nginx
systemctl start sales-ops

echo "  Waiting for backend..."
for i in $(seq 1 30); do
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost:${HTTPS_PORT}/" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo "  Backend is healthy! (HTTP $HTTP_CODE)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  WARNING: Backend did not respond within 30 seconds."
        echo "  Check logs: journalctl -u sales-ops -f"
    fi
    sleep 1
done

# Configure automatic backup cron
echo "  Configuring daily backup cron..."
echo "0 2 * * * root $DEPLOY_DIR/scripts/backup.sh >> /var/log/sales-ops-backup.log 2>&1" \
    > /etc/cron.d/sales-ops-backup
chmod 644 /etc/cron.d/sales-ops-backup

echo ""
echo "============================================="
echo "  Setup Complete!"
echo "============================================="
echo ""
echo "  Access: https://${SERVER_IP:-localhost}:${HTTPS_PORT}"
echo "  Login:  admin"
if [ -n "${SEED_ADMIN_PASSWORD:-}" ]; then
    echo "  初始管理员密码（首次登录后请立即修改）: ${SEED_ADMIN_PASSWORD}"
    echo "  该密码已写入 $DEPLOY_DIR/config/.env 的 SEED_ADMIN_PASSWORD 变量"
else
    echo "  初始管理员密码：请查看 $DEPLOY_DIR/config/.env 中的 SEED_ADMIN_PASSWORD"
fi
echo ""
echo "  Services:"
echo "    systemctl status sales-ops"
echo "    systemctl status nginx"
echo "    systemctl status postgresql"
echo "    systemctl status valkey-server"
echo "    systemctl status seaweedfs-master"
echo ""
echo "  Logs:    journalctl -u sales-ops -f"
echo "  Backup:  Daily at 2:00 AM → /opt/sales-ops-backups/"
echo "  Update:  sudo $DEPLOY_DIR/scripts/deploy.sh"
echo ""
