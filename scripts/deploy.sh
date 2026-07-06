#!/usr/bin/env bash
# Sales Operations Platform — Update Deploy Script
# Usage: sudo ./scripts/deploy.sh
# Pulls latest from distribution repo and restarts all services.
# NOTE: Database migrations run automatically via sqlx::migrate!() on backend startup.
set -euo pipefail

DEPLOY_DIR="/opt/sales-ops"
BACKUP_DIR="/opt/sales-ops-backups/$(date +%Y%m%d-%H%M%S)"
SERVICE_USER="sales-ops"

echo "============================================="
echo "  Sales Operations Platform — Deploy Update"
echo "============================================="

# ── Step 1: Backup current version ──────────────────────────────
echo ""
if [ -d "$DEPLOY_DIR/backend" ]; then
    echo "[1/6] Backing up current version..."
    mkdir -p "$BACKUP_DIR"
    cp -r "$DEPLOY_DIR/backend" "$BACKUP_DIR/"
    cp -r "$DEPLOY_DIR/frontend" "$BACKUP_DIR/"
    cp "$DEPLOY_DIR/config/.env" "$BACKUP_DIR/env.bak" 2>/dev/null || true
    cp "$DEPLOY_DIR/rbac_model.conf" "$BACKUP_DIR/" 2>/dev/null || true
    echo "  Backup saved to $BACKUP_DIR"
else
    echo "[1/6] No existing deployment, skipping backup."
fi

# ── Step 2: Pull latest from distribution repo ──────────────────
echo "[2/6] Pulling latest release..."
cd "$DEPLOY_DIR"
git pull origin main || {
    echo "  ERROR: git pull failed. Check network or repo access."
    exit 1
}

# ── Step 3: Fix CRLF line endings (Windows-created files) ────────
echo "[3/6] Fixing CRLF line endings..."
find "$DEPLOY_DIR" -type f \( -name "*.env" -o -name "*.sh" -o -name "*.conf" \) \
    -exec sed -i 's/\r$//' {} \; 2>/dev/null || true

# ── Step 4: Set permissions ─────────────────────────────────────
echo "[4/6] Setting permissions..."
chmod +x "$DEPLOY_DIR/backend/sales-operations-platform"
chmod +x "$DEPLOY_DIR/scripts/"*.sh 2>/dev/null || true
chown -R "$SERVICE_USER:$SERVICE_USER" "$DEPLOY_DIR"

# ── Step 5: Reload systemd + restart services ───────────────────
echo "[5/6] Restarting services..."
systemctl daemon-reload
systemctl restart sales-ops
systemctl reload nginx 2>/dev/null || systemctl restart nginx

# ── Step 6: Health check ────────────────────────────────────────
echo "[6/6] Waiting for backend to start..."
for i in $(seq 1 30); do
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:8089/ 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo "  Backend is healthy! (HTTP $HTTP_CODE)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  WARNING: Backend did not respond within 30 seconds."
        echo "  Check logs: journalctl -u sales-ops -f"
        exit 1
    fi
    sleep 1
done

echo ""
echo "============================================="
echo "  Deploy complete!"
echo "============================================="
echo "Backend:  systemctl status sales-ops"
echo "Nginx:    systemctl status nginx"
echo "Logs:     journalctl -u sales-ops -f"
echo "URL:      https://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):8089"
