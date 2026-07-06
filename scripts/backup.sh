#!/usr/bin/env bash
# Sales Operations Platform — Backup Script
# Usage: sudo ./scripts/backup.sh
# Backs up database, config, SeaweedFS data, and uploaded files.
# Designed for cron: 0 2 * * * root /opt/sales-ops/scripts/backup.sh >> /var/log/sales-ops-backup.log 2>&1
set -euo pipefail

DEPLOY_DIR="/opt/sales-ops"
BACKUP_ROOT="/opt/sales-ops-backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
RETENTION_DAYS=7

echo "[$(date)] === Backup started ==="

mkdir -p "$BACKUP_DIR"

# ── Step 1: PostgreSQL dump (custom format) ──────────────────────
echo "[$(date)] [1/4] Dumping PostgreSQL database..."
if command -v pg_dump &>/dev/null; then
    sudo -u postgres pg_dump -Fc sales_ops > "$BACKUP_DIR/db-$TIMESTAMP.dump"
    echo "[$(date)]   Database backup: $(du -h "$BACKUP_DIR/db-$TIMESTAMP.dump" | cut -f1)"
else
    echo "[$(date)]   WARNING: pg_dump not found, skipping database backup."
fi

# ── Step 2: SeaweedFS data backup ────────────────────────────────
echo "[$(date)] [2/4] Backing up SeaweedFS data..."
SEAWEEDFS_DATA="/var/lib/seaweedfs"
if [ -d "$SEAWEEDFS_DATA" ]; then
    tar czf "$BACKUP_DIR/seaweedfs-$TIMESTAMP.tar.gz" -C "$SEAWEEDFS_DATA" .
    echo "[$(date)]   SeaweedFS backup: $(du -h "$BACKUP_DIR/seaweedfs-$TIMESTAMP.tar.gz" | cut -f1)"
else
    echo "[$(date)]   SeaweedFS data dir not found at $SEAWEEDFS_DATA, skipping."
fi

# ── Step 3: Config backup (.env + nginx + systemd) ───────────────
echo "[$(date)] [3/4] Backing up configuration..."
cp "$DEPLOY_DIR/config/.env" "$BACKUP_DIR/env-$TIMESTAMP.bak" 2>/dev/null || true
cp "$DEPLOY_DIR/rbac_model.conf" "$BACKUP_DIR/rbac_model-$TIMESTAMP.conf" 2>/dev/null || true
echo "[$(date)]   Config backup done."

# ── Step 4: Cleanup old backups ──────────────────────────────────
echo "[$(date)] [4/4] Cleaning backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_ROOT" -name "db-*.dump" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
find "$BACKUP_ROOT" -name "seaweedfs-*.tar.gz" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
find "$BACKUP_ROOT" -name "env-*.bak" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
find "$BACKUP_ROOT" -name "rbac_model-*.conf" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
# Also clean old backup directories (from deploy.sh)
find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true

echo "[$(date)] === Backup complete: $BACKUP_DIR ==="
ls -lh "$BACKUP_DIR"
#!/usr/bin/env bash
# Sales Operations Platform — Backup Script
# Usage: sudo ./backup.sh
# Backs up database, config, and uploaded files

set -euo pipefail

BACKUP_ROOT="/opt/sales-ops-backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
DEPLOY_DIR="/opt/sales-ops"
RETENTION_DAYS=30

echo "=== Sales Operations Platform Backup ==="

mkdir -p "$BACKUP_DIR"

# Step 1: Database dump
echo "[1/4] Dumping database..."
set -a; source "$DEPLOY_DIR/config/.env"; set +a
pg_dump "$DATABASE_URL" | gzip > "$BACKUP_DIR/database.sql.gz"
echo "  Database backup: $(du -h "$BACKUP_DIR/database.sql.gz" | cut -f1)"

# Step 2: Config backup
echo "[2/4] Backing up config..."
cp -r "$DEPLOY_DIR/config" "$BACKUP_DIR/config"

# Step 3: SeaweedFS uploaded files backup (if data dir exists)
echo "[3/4] Backing up uploaded files..."
SEAWEEDFS_DATA="/opt/seaweedfs/data"
if [ -d "$SEAWEEDFS_DATA" ]; then
    tar czf "$BACKUP_DIR/seaweedfs-data.tar.gz" -C "$(dirname "$SEAWEEDFS_DATA")" "$(basename "$SEAWEEDFS_DATA")"
    echo "  SeaweedFS backup: $(du -h "$BACKUP_DIR/seaweedfs-data.tar.gz" | cut -f1)"
else
    echo "  SeaweedFS data dir not found at $SEAWEEDFS_DATA, skipping."
fi

# Step 4: Cleanup old backups
echo "[4/4] Cleaning backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true

echo "=== Backup complete: $BACKUP_DIR ==="
ls -lh "$BACKUP_DIR"
