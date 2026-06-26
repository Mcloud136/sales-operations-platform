#!/usr/bin/env bash
#
# monitor.sh - Lightweight monitoring for Sales Operations Platform
# Usage:
#   bash monitor.sh              # Run all checks (usually called by cron)
#   bash monitor.sh --disk       # Only disk check
#   bash monitor.sh --processes  # Only process check
#   bash monitor.sh --all        # Run all checks (same as no args)
#
# Environment Variables (or set in .env):
#   WEBHOOK_URL       - Webhook URL for alerts (DingTalk/WeCom/Slack)
#   WEBHOOK_TYPE      - "dingtalk", "wecom", or "slack" (default: slack)
#   DISK_THRESHOLD    - Disk usage % threshold (default: 85)
#   PG_MAX_CONN_PCT  - Max PG connection usage % threshold (default: 90)
#   VALKEY_MEM_PCT   - Max Valkey memory usage % threshold (default: 85)
#   SERVER_NAME       - Human-readable server name for alerts
#
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_DIR="/opt/sales-ops"
CURRENT_LINK="${APP_DIR}/current"
LOG_DIR="${APP_DIR}/logs"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
SERVER_NAME="${SERVER_NAME:-$(hostname -f)}"

# Load .env if exists
if [[ -f "${CURRENT_LINK}/backend/.env" ]]; then
    # shellcheck disable=SC1090
    source "${CURRENT_LINK}/backend/.env"
fi

# Thresholds
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
PG_MAX_CONN_PCT="${PG_MAX_CONN_PCT:-90}"
VALKEY_MEM_PCT="${VALKEY_MEM_PCT:-85}"

# Webhook configuration
WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_TYPE="${WEBHOOK_TYPE:-slack}"

# Database
DB_NAME="${DB_NAME:-salesops}"
DB_USER="${DB_USER:-salesops}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_HOST="${DB_HOST:-/var/run/postgresql}"
DB_PORT="${DB_PORT:-5432}"

# Valkey
VALKEY_SOCK="${VALKEY_SOCK:-/var/run/valkey/valkey.sock}"
VALKEY_PASSWORD="${VALKEY_PASSWORD:-}"

# Alert state tracking (prevent alert spam)
ALERT_STATE_DIR="/tmp/sales-ops-monitor"
ALERT_COOLDOWN=1800  # 30 minutes between repeated alerts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[MONITOR]${NC} ${TIMESTAMP} $*"; }
warn()  { echo -e "${YELLOW}[MONITOR-WARN]${NC} ${TIMESTAMP} $*"; }
error() { echo -e "${RED}[MONITOR-ERROR]${NC} ${TIMESTAMP} $*" >&2; }

# Track alert state to avoid spamming
mkdir -p "${ALERT_STATE_DIR}"

should_alert() {
    local alert_name="$1"
    local state_file="${ALERT_STATE_DIR}/${alert_name}"

    if [[ -f "${state_file}" ]]; then
        local last_alert
        last_alert=$(stat -c%Y "${state_file}" 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        local elapsed=$((now - last_alert))

        if [[ ${elapsed} -lt ${ALERT_COOLDOWN} ]]; then
            return 1  # Skip, cooldown not expired
        fi
    fi

    date +%s > "${state_file}"
    return 0  # OK to alert
}

# ---------------------------------------------------------------------------
# Send webhook alert
# ---------------------------------------------------------------------------
send_alert() {
    local title="$1"
    local message="$2"
    local severity="${3:-warning}"  # warning, critical

    # Log locally regardless
    if [[ "${severity}" == "critical" ]]; then
        error "[${severity^^}] ${title}: ${message}"
    else
        warn "[${severity^^}] ${title}: ${message}"
    fi

    # Send webhook if configured
    if [[ -z "${WEBHOOK_URL}" ]]; then
        return
    fi

    local color="warning"
    if [[ "${severity}" == "critical" ]]; then
        color="danger"
    fi

    case "${WEBHOOK_TYPE}" in
        dingtalk)
            # DingTalk robot webhook
            local payload
            payload=$(cat <<EOF
{
    "msgtype": "markdown",
    "markdown": {
        "title": "${title}",
        "text": "### ${severity^^}: ${title}\n\n**Server:** ${SERVER_NAME}\n\n**Time:** ${TIMESTAMP}\n\n${message}"
    }
}
EOF
)
            curl -fsSL -X POST -H 'Content-Type: application/json' \
                -d "${payload}" "${WEBHOOK_URL}" > /dev/null 2>&1 || true
            ;;
        wecom)
            # WeCom (WeCom Work) robot webhook
            local payload
            payload=$(cat <<EOF
{
    "msgtype": "markdown",
    "markdown": {
        "content": "### <font color=\"${color}\">${severity^^}</font>: ${title}\n> Server: **${SERVER_NAME}**\n> Time: ${TIMESTAMP}\n> ${message}"
    }
}
EOF
)
            curl -fsSL -X POST -H 'Content-Type: application/json' \
                -d "${payload}" "${WEBHOOK_URL}" > /dev/null 2>&1 || true
            ;;
        slack|*)
            # Slack Incoming Webhook
            local emoji=":warning:"
            if [[ "${severity}" == "critical" ]]; then
                emoji=":rotating_light:"
            fi
            local payload
            payload=$(cat <<EOF
{
    "attachments": [
        {
            "color": "${color}",
            "title": "${emoji} [${severity^^}] ${title}",
            "fields": [
                {"title": "Server", "value": "${SERVER_NAME}", "short": true},
                {"title": "Time", "value": "${TIMESTAMP}", "short": true},
                {"title": "Detail", "value": "${message}", "short": false}
            ]
        }
    ]
}
EOF
)
            curl -fsSL -X POST -H 'Content-Type: application/json' \
                -d "${payload}" "${WEBHOOK_URL}" > /dev/null 2>&1 || true
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Check: Disk usage
# ---------------------------------------------------------------------------
check_disk() {
    local disk_usage
    disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

    if [[ ${disk_usage} -ge ${DISK_THRESHOLD} ]]; then
        if should_alert "disk_usage"; then
            send_alert "Disk Usage Critical" \
                "Root partition usage at ${disk_usage}% (threshold: ${DISK_THRESHOLD}%)" \
                "critical"
        fi
        error "  [FAIL] Disk usage: ${disk_usage}% (threshold: ${DISK_THRESHOLD}%)"
        return 1
    else
        info "  [OK] Disk usage: ${disk_usage}%"
    fi
}

# ---------------------------------------------------------------------------
# Check: Core processes
# ---------------------------------------------------------------------------
check_processes() {
    local failed=0

    # PostgreSQL
    if pgrep -x postgres > /dev/null || pgrep -f "postgres.*-D" > /dev/null; then
        info "  [OK] PostgreSQL process running"
    else
        if should_alert "process_postgresql"; then
            send_alert "PostgreSQL Down" "PostgreSQL process is not running" "critical"
        fi
        error "  [FAIL] PostgreSQL process NOT running"
        failed=1
    fi

    # Valkey
    if pgrep -x valkey-server > /dev/null || pgrep -f "valkey-server" > /dev/null; then
        info "  [OK] Valkey process running"
    else
        if should_alert "process_valkey"; then
            send_alert "Valkey Down" "Valkey process is not running" "critical"
        fi
        error "  [FAIL] Valkey process NOT running"
        failed=1
    fi

    # Backend (Uvicorn)
    if systemctl is-active sales-ops-backend &>/dev/null; then
        info "  [OK] sales-ops-backend active"
    else
        if should_alert "process_backend"; then
            send_alert "Backend Down" "sales-ops-backend service is not active" "critical"
        fi
        error "  [FAIL] sales-ops-backend NOT active"
        failed=1
    fi

    # Celery worker
    if systemctl is-active sales-ops-celery &>/dev/null; then
        info "  [OK] sales-ops-celery active"
    else
        if should_alert "process_celery"; then
            send_alert "Celery Down" "sales-ops-celery service is not active" "critical"
        fi
        error "  [FAIL] sales-ops-celery NOT active"
        failed=1
    fi

    return ${failed}
}

# ---------------------------------------------------------------------------
# Check: PostgreSQL connection count
# ---------------------------------------------------------------------------
check_pg_connections() {
    local max_connections
    local current_connections

    # Get max_connections from PostgreSQL
    max_connections=$(psql -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" \
        -tAc "SHOW max_connections" 2>/dev/null || echo "100")
    max_connections=$(echo "${max_connections}" | tr -d '[:space:]')

    # Get current connection count (excluding our monitoring connection)
    current_connections=$(psql -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" \
        -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='${DB_NAME}'" 2>/dev/null || echo "0")
    current_connections=$(echo "${current_connections}" | tr -d '[:space:]')

    local usage_pct=0
    if [[ ${max_connections} -gt 0 ]]; then
        usage_pct=$((current_connections * 100 / max_connections))
    fi

    if [[ ${usage_pct} -ge ${PG_MAX_CONN_PCT} ]]; then
        if should_alert "pg_connections"; then
            send_alert "PostgreSQL Connections High" \
                "Current: ${current_connections}/${max_connections} (${usage_pct}%) -- threshold: ${PG_MAX_CONN_PCT}%" \
                "warning"
        fi
        warn "  [WARN] PG connections: ${current_connections}/${max_connections} (${usage_pct}%)"
        return 1
    else
        info "  [OK] PG connections: ${current_connections}/${max_connections} (${usage_pct}%)"
    fi
}

# ---------------------------------------------------------------------------
# Check: Valkey memory usage
# ---------------------------------------------------------------------------
check_valkey_memory() {
    local valkey_cli="valkey-cli"
    local valkey_cli_opts=(-s "${VALKEY_SOCK}")
    if [[ -n "${VALKEY_PASSWORD}" ]]; then
        valkey_cli_opts+=(-a "${VALKEY_PASSWORD}" --no-auth-warning)
    fi

    local used_memory
    local maxmemory
    used_memory=$(${valkey_cli} "${valkey_cli_opts[@]}" INFO memory 2>/dev/null \
        | grep "^used_memory:" | cut -d: -f2 || echo "0")
    maxmemory=$(${valkey_cli} "${valkey_cli_opts[@]}" INFO memory 2>/dev/null \
        | grep "^maxmemory:" | cut -d: -f2 || echo "0")

    used_memory=$(echo "${used_memory}" | tr -d '[:space:]')
    maxmemory=$(echo "${maxmemory}" | tr -d '[:space:]')

    if [[ ${maxmemory} -eq 0 ]]; then
        info "  [OK] Valkey memory: no maxmemory configured"
        return 0
    fi

    local usage_pct=0
    usage_pct=$((used_memory * 100 / maxmemory))

    # Convert to human-readable
    local used_mb=$((used_memory / 1024 / 1024))
    local max_mb=$((maxmemory / 1024 / 1024))

    if [[ ${usage_pct} -ge ${VALKEY_MEM_PCT} ]]; then
        if should_alert "valkey_memory"; then
            send_alert "Valkey Memory High" \
                "Usage: ${used_mb}MB/${max_mb}MB (${usage_pct}%) -- threshold: ${VALKEY_MEM_PCT}%" \
                "warning"
        fi
        warn "  [WARN] Valkey memory: ${used_mb}MB/${max_mb}MB (${usage_pct}%)"
        return 1
    else
        info "  [OK] Valkey memory: ${used_mb}MB/${max_mb}MB (${usage_pct}%)"
    fi
}

# ---------------------------------------------------------------------------
# Check: Backup age
# ---------------------------------------------------------------------------
check_backup_age() {
    local pg_backup
    pg_backup=$(find /opt/sales-ops/backups/postgresql -name "${DB_NAME}_*_dump" -type f \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')

    if [[ -z "${pg_backup}" ]]; then
        if should_alert "backup_missing"; then
            send_alert "No Backup Found" "No PostgreSQL backup exists" "critical"
        fi
        warn "  [WARN] No PostgreSQL backup found"
        return 1
    fi

    local backup_age_hours
    backup_age_hours=$(( ($(date +%s) - $(stat -c%Y "${pg_backup}")) / 3600 ))

    if [[ ${backup_age_hours} -gt 48 ]]; then
        if should_alert "backup_stale"; then
            send_alert "Backup Too Old" \
                "Last backup is ${backup_age_hours} hours old (>48h threshold)" \
                "warning"
        fi
        warn "  [WARN] Last backup is ${backup_age_hours} hours old"
        return 1
    else
        info "  [OK] Last backup: ${backup_age_hours} hours ago"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="${1:---all}"
    info "Monitor check starting..."

    local errors=0

    case "${mode}" in
        --disk)
            check_disk || errors=$((errors + 1))
            ;;
        --processes)
            check_processes || errors=$((errors + 1))
            ;;
        --pg)
            check_pg_connections || errors=$((errors + 1))
            ;;
        --valkey)
            check_valkey_memory || errors=$((errors + 1))
            ;;
        --backup)
            check_backup_age || errors=$((errors + 1))
            ;;
        --all|*)
            check_disk || errors=$((errors + 1))
            check_processes || errors=$((errors + 1))
            check_pg_connections || errors=$((errors + 1))
            check_valkey_memory || errors=$((errors + 1))
            check_backup_age || errors=$((errors + 1))
            ;;
    esac

    if [[ ${errors} -gt 0 ]]; then
        warn "Monitor check complete: ${errors} warning(s)/failure(s)"
    else
        info "Monitor check complete: all checks passed"
    fi
}

main "$@"
