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
