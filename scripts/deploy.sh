#!/usr/bin/env bash
# Sales Operations Platform — Deploy Script
# Usage: sudo ./deploy.sh
# Pulls latest from distribution repo and restarts services

set -euo pipefail

DEPLOY_DIR="/opt/sales-ops"
DIST_REPO="https://gitee.com/wxbns/sales-operations-platform.git"
BACKUP_DIR="/opt/sales-ops-backups/$(date +%Y%m%d-%H%M%S)"

echo "=== Sales Operations Platform Deploy ==="

# Step 1: Backup current version
if [ -d "$DEPLOY_DIR/backend" ]; then
    echo "[1/5] Backing up current version..."
    mkdir -p "$BACKUP_DIR"
    cp -r "$DEPLOY_DIR/backend" "$BACKUP_DIR/"
    cp -r "$DEPLOY_DIR/frontend" "$BACKUP_DIR/"
    cp -r "$DEPLOY_DIR/migrations" "$BACKUP_DIR/"
    echo "  Backup saved to $BACKUP_DIR"
else
    echo "[1/5] No existing deployment, skipping backup."
fi

# Step 2: Pull latest from distribution repo
echo "[2/5] Pulling latest release..."
if [ -d "$DEPLOY_DIR/.git" ]; then
    cd "$DEPLOY_DIR"
    git pull origin main
else
    mkdir -p "$DEPLOY_DIR"
    git clone "$DIST_REPO" "$DEPLOY_DIR"
fi

# Step 3: Set permissions
echo "[3/5] Setting permissions..."
chmod +x "$DEPLOY_DIR/backend/sales-operations-platform"
chmod +x "$DEPLOY_DIR/scripts/"*.sh 2>/dev/null || true

# Step 4: Reload systemd (in case service file changed) + restart backend
# Note: Database migrations run automatically via sqlx::migrate!() on backend startup
echo "[4/5] Restarting backend service..."
systemctl daemon-reload
systemctl restart sales-ops

# Step 5: Reload nginx + health check
echo "[5/5] Reloading nginx..."
systemctl reload nginx

# Wait for backend to start and run health check
echo "Waiting for backend to start..."
for i in $(seq 1 30); do
    if curl -sk https://localhost:8089/api/dashboard/stats > /dev/null 2>&1; then
        echo "  Backend is healthy!"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  WARNING: Backend did not respond within 30 seconds."
        echo "  Check logs: journalctl -u sales-ops -f"
        exit 1
    fi
    sleep 1
done

echo "=== Deploy complete ==="
echo "Backend: systemctl status sales-ops"
echo "Nginx:   systemctl status nginx"
echo "Logs:    journalctl -u sales-ops -f"
