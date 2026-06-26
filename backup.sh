#!/usr/bin/env bash
#
# backup.sh - Backup script for Sales Operations Platform
# Usage:
#   bash backup.sh              # Run backup (usually called by cron)
#   bash backup.sh --verify     # Verify last backup integrity
#   bash backup.sh --test-restore  # Test restore to temporary DB
#
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_DIR="/opt/sales-ops"
CURRENT_LINK="${APP_DIR}/current"
BACKUP_BASE="/opt/sales-ops/backups"
PG_BACKUP_DIR="${BACKUP_BASE}/postgresql"
VALKEY_BACKUP_DIR="${BACKUP_BASE}/valkey"
LOG_DIR="${APP_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_ONLY=$(date +%Y%m%d)
DAY_OF_WEEK=$(date +%u)   # 1=Monday
DAY_OF_MONTH=$(date +%d)

# Load .env if exists
if [[ -f "${CURRENT_LINK}/backend/.env" ]]; then
    # shellcheck disable=SC1090
    source "${CURRENT_LINK}/backend/.env"
fi

# Database settings (with defaults)
DB_NAME="${DB_NAME:-salesops}"
DB_USER="${DB_USER:-salesops}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_HOST="${DB_HOST:-/var/run/postgresql}"
DB_PORT="${DB_PORT:-5432}"

# Valkey settings
VALKEY_SOCK="${VALKEY_SOCK:-/var/run/valkey/valkey.sock}"
VALKEY_PASSWORD="${VALKEY_PASSWORD:-}"

# Retention policy
DAILY_KEEP=7
WEEKLY_KEEP=4
MONTHLY_KEEP=12

# Remote backup settings (optional)
REMOTE_BACKUP_ENABLED="${REMOTE_BACKUP_ENABLED:-false}"
REMOTE_BACKUP_TARGET="${REMOTE_BACKUP_TARGET:-}"
# Supported: rsync://user@host:/path, rclone:bucketname:path

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[BACKUP]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn()  { echo -e "${YELLOW}[BACKUP-WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }
error() { echo -e "${RED}[BACKUP-ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# ---------------------------------------------------------------------------
# PostgreSQL backup
# ---------------------------------------------------------------------------
backup_postgresql() {
    info "Starting PostgreSQL backup..."

    mkdir -p "${PG_BACKUP_DIR}"

    local backup_file="${PG_BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.dump"

    local pg_opts=(-Fc -Z9 -f "${backup_file}" -d "${DB_NAME}")
    if [[ -n "${DB_PASSWORD}" ]]; then
        export PGPASSWORD="${DB_PASSWORD}"
    fi
    pg_opts+=(-U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}")

    if pg_dump "${pg_opts[@]}" 2>>"${LOG_DIR}/backup.log"; then
        local size
        size=$(du -h "${backup_file}" | cut -f1)
        info "PostgreSQL backup complete: ${backup_file} (${size})"
    else
        error "PostgreSQL backup FAILED"
        unset PGPASSWORD
        return 1
    fi

    unset PGPASSWORD
}

# ---------------------------------------------------------------------------
# Valkey backup
# ---------------------------------------------------------------------------
backup_valkey() {
    info "Starting Valkey backup..."

    mkdir -p "${VALKEY_BACKUP_DIR}"

    # Trigger BGSAVE (background save)
    local valkey_cli="valkey-cli"
    local valkey_cli_opts=(-s "${VALKEY_SOCK}")
    if [[ -n "${VALKEY_PASSWORD}" ]]; then
        valkey_cli_opts+=(-a "${VALKEY_PASSWORD}" --no-auth-warning)
    fi

    # Check if a BGSAVE is already running
    local last_save
    last_save=$(${valkey_cli} "${valkey_cli_opts[@]}" LASTSAVE 2>/dev/null || echo "0")

    ${valkey_cli} "${valkey_cli_opts[@]}" BGSAVE 2>/dev/null || {
        warn "Valkey BGSAVE failed (may be in progress already)"
        # Wait and try once more
        sleep 5
        ${valkey_cli} "${valkey_cli_opts[@]}" BGSAVE 2>/dev/null || {
            warn "Valkey BGSAVE failed again, copying existing RDB"
        }
    }

    # Wait for BGSAVE to complete (up to 60 seconds)
    local wait_count=0
    while [[ ${wait_count} -lt 30 ]]; do
        local new_last_save
        new_last_save=$(${valkey_cli} "${valkey_cli_opts[@]}" LASTSAVE 2>/dev/null || echo "0")
        if [[ "${new_last_save}" != "${last_save}" ]]; then
            break
        fi
        sleep 2
        wait_count=$((wait_count + 1))
    done

    if [[ ${wait_count} -ge 30 ]]; then
        warn "Valkey BGSAVE did not complete within 60 seconds"
    fi

    # Copy RDB file
    local rdb_source="/var/lib/valkey/dump.rdb"
    if [[ -f "${rdb_source}" ]]; then
        local backup_file="${VALKEY_BACKUP_DIR}/valkey_${TIMESTAMP}.rdb"
        cp "${rdb_source}" "${backup_file}"
        local size
        size=$(du -h "${backup_file}" | cut -f1)
        info "Valkey backup complete: ${backup_file} (${size})"
    else
        warn "Valkey RDB file not found at ${rdb_source}"
    fi
}

# ---------------------------------------------------------------------------
# Rotate backups
# ---------------------------------------------------------------------------
rotate_backups() {
    info "Rotating backups..."

    # --- PostgreSQL ---
    # Daily: keep last N
    local daily_count
    daily_count=$(find "${PG_BACKUP_DIR}" -name "${DB_NAME}_*_dump" -type f | wc -l)
    if [[ ${daily_count} -gt ${DAILY_KEEP} ]]; then
        find "${PG_BACKUP_DIR}" -name "${DB_NAME}_*_dump" -type f -printf '%T@ %p\n' \
            | sort -n | head -n $((daily_count - DAILY_KEEP)) \
            | awk '{print $2}' | xargs rm -f
        info "Rotated PostgreSQL daily backups (kept ${DAILY_KEEP})"
    fi

    # Weekly: keep N (copy every Sunday to weekly dir)
    local weekly_dir="${BACKUP_BASE}/weekly/postgresql"
    if [[ ${DAY_OF_WEEK} -eq 7 ]]; then
        mkdir -p "${weekly_dir}"
        local latest_dump
        latest_dump=$(find "${PG_BACKUP_DIR}" -name "${DB_NAME}_*_dump" -type f -printf '%T@ %p\n' \
            | sort -rn | head -1 | awk '{print $2}')
        if [[ -n "${latest_dump}" && -f "${latest_dump}" ]]; then
            cp "${latest_dump}" "${weekly_dir}/weekly_${DATE_ONLY}.dump"
        fi
        local weekly_count
        weekly_count=$(find "${weekly_dir}" -name "weekly_*.dump" -type f | wc -l)
        if [[ ${weekly_count} -gt ${WEEKLY_KEEP} ]]; then
            find "${weekly_dir}" -name "weekly_*.dump" -type f -printf '%T@ %p\n' \
                | sort -n | head -n $((weekly_count - WEEKLY_KEEP)) \
                | awk '{print $2}' | xargs rm -f
        fi
    fi

    # Monthly: keep N (copy on 1st of month to monthly dir)
    local monthly_dir="${BACKUP_BASE}/monthly/postgresql"
    if [[ ${DAY_OF_MONTH} -eq 01 ]]; then
        mkdir -p "${monthly_dir}"
        local latest_dump
        latest_dump=$(find "${PG_BACKUP_DIR}" -name "${DB_NAME}_*_dump" -type f -printf '%T@ %p\n' \
            | sort -rn | head -1 | awk '{print $2}')
        if [[ -n "${latest_dump}" && -f "${latest_dump}" ]]; then
            cp "${latest_dump}" "${monthly_dir}/monthly_${DATE_ONLY}.dump"
        fi
        local monthly_count
        monthly_count=$(find "${monthly_dir}" -name "monthly_*.dump" -type f | wc -l)
        if [[ ${monthly_count} -gt ${MONTHLY_KEEP} ]]; then
            find "${monthly_dir}" -name "monthly_*.dump" -type f -printf '%T@ %p\n' \
                | sort -n | head -n $((monthly_count - MONTHLY_KEEP)) \
                | awk '{print $2}' | xargs rm -f
        fi
    fi

    # --- Valkey ---
    local v_daily_count
    v_daily_count=$(find "${VALKEY_BACKUP_DIR}" -name "valkey_*.rdb" -type f | wc -l)
    if [[ ${v_daily_count} -gt ${DAILY_KEEP} ]]; then
        find "${VALKEY_BACKUP_DIR}" -name "valkey_*.rdb" -type f -printf '%T@ %p\n' \
            | sort -n | head -n $((v_daily_count - DAILY_KEEP)) \
            | awk '{print $2}' | xargs rm -f
        info "Rotated Valkey daily backups (kept ${DAILY_KEEP})"
    fi

    # Valkey weekly
    local v_weekly_dir="${BACKUP_BASE}/weekly/valkey"
    if [[ ${DAY_OF_WEEK} -eq 7 ]]; then
        mkdir -p "${v_weekly_dir}"
        local latest_rdb
        latest_rdb=$(find "${VALKEY_BACKUP_DIR}" -name "valkey_*.rdb" -type f -printf '%T@ %p\n' \
            | sort -rn | head -1 | awk '{print $2}')
        if [[ -n "${latest_rdb}" && -f "${latest_rdb}" ]]; then
            cp "${latest_rdb}" "${v_weekly_dir}/weekly_${DATE_ONLY}.rdb"
        fi
        local v_weekly_count
        v_weekly_count=$(find "${v_weekly_dir}" -name "weekly_*.rdb" -type f | wc -l)
        if [[ ${v_weekly_count} -gt ${WEEKLY_KEEP} ]]; then
            find "${v_weekly_dir}" -name "weekly_*.rdb" -type f -printf '%T@ %p\n' \
                | sort -n | head -n $((v_weekly_count - WEEKLY_KEEP)) \
                | awk '{print $2}' | xargs rm -f
        fi
    fi

    # Valkey monthly
    local v_monthly_dir="${BACKUP_BASE}/monthly/valkey"
    if [[ ${DAY_OF_MONTH} -eq 01 ]]; then
        mkdir -p "${v_monthly_dir}"
        local latest_rdb
        latest_rdb=$(find "${VALKEY_BACKUP_DIR}" -name "valkey_*.rdb" -type f -printf '%T@ %p\n' \
            | sort -rn | head -1 | awk '{print $2}')
        if [[ -n "${latest_rdb}" && -f "${latest_rdb}" ]]; then
            cp "${latest_rdb}" "${v_monthly_dir}/monthly_${DATE_ONLY}.rdb"
        fi
        local v_monthly_count
        v_monthly_count=$(find "${v_monthly_dir}" -name "monthly_*.rdb" -type f | wc -l)
        if [[ ${v_monthly_count} -gt ${MONTHLY_KEEP} ]]; then
            find "${v_monthly_dir}" -name "monthly_*.rdb" -type f -printf '%T@ %p\n' \
                | sort -n | head -n $((v_monthly_count - MONTHLY_KEEP)) \
                | awk '{print $2}' | xargs rm -f
        fi
    fi

    info "Backup rotation complete"
}

# ---------------------------------------------------------------------------
# Remote sync (optional)
# ---------------------------------------------------------------------------
remote_sync() {
    if [[ "${REMOTE_BACKUP_ENABLED}" != "true" || -z "${REMOTE_BACKUP_TARGET}" ]]; then
        return
    fi

    info "Syncing backups to remote: ${REMOTE_BACKUP_TARGET}"

    case "${REMOTE_BACKUP_TARGET}" in
        rsync://*)
            rsync -az --delete "${BACKUP_BASE}/" "${REMOTE_BACKUP_TARGET}" \
                >> "${LOG_DIR}/backup.log" 2>&1 || warn "Remote rsync sync failed"
            ;;
        rclone:*)
            rclone sync "${BACKUP_BASE}/" "${REMOTE_BACKUP_TARGET}" \
                >> "${LOG_DIR}/backup.log" 2>&1 || warn "Remote rclone sync failed"
            ;;
        *)
            warn "Unknown remote backup target format: ${REMOTE_BACKUP_TARGET}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Verify last backup
# ---------------------------------------------------------------------------
verify_backup() {
    info "Verifying last backup..."

    # Verify PostgreSQL backup
    local last_pg_dump
    last_pg_dump=$(find "${PG_BACKUP_DIR}" -name "${DB_NAME}_*_dump" -type f \
        -printf '%T@ %p\n' | sort -rn | head -1 | awk '{print $2}')

    if [[ -n "${last_pg_dump}" && -f "${last_pg_dump}" ]]; then
        if pg_restore -l "${last_pg_dump}" &>/dev/null; then
            info "  [OK] PostgreSQL backup valid: ${last_pg_dump}"
        else
            error "  [FAIL] PostgreSQL backup CORRUPTED: ${last_pg_dump}"
            return 1
        fi
    else
        warn "  [WARN] No PostgreSQL backup found"
    fi

    # Verify Valkey backup
    local last_rdb
    last_rdb=$(find "${VALKEY_BACKUP_DIR}" -name "valkey_*.rdb" -type f \
        -printf '%T@ %p\n' | sort -rn | head -1 | awk '{print $2}')

    if [[ -n "${last_rdb}" && -f "${last_rdb}" ]]; then
        local file_size
        file_size=$(stat -c%s "${last_rdb}")
        if [[ ${file_size} -gt 0 ]]; then
            info "  [OK] Valkey backup valid: ${last_rdb} ($(du -h "${last_rdb}" | cut -f1))"
        else
            error "  [FAIL] Valkey backup EMPTY: ${last_rdb}"
            return 1
        fi
    else
        warn "  [WARN] No Valkey backup found"
    fi
}

# ---------------------------------------------------------------------------
# Test restore (to temporary DB)
# ---------------------------------------------------------------------------
test_restore() {
    info "Testing restore to temporary database..."

    local last_pg_dump
    last_pg_dump=$(find "${PG_BACKUP_DIR}" -name "${DB_NAME}_*_dump" -type f \
        -printf '%T@ %p\n' | sort -rn | head -1 | awk '{print $2}')

    if [[ -z "${last_pg_dump}" || ! -f "${last_pg_dump}" ]]; then
        error "No backup to restore"
        return 1
    fi

    local test_db="${DB_NAME}_restore_test_$$"
    if [[ -n "${DB_PASSWORD}" ]]; then
        export PGPASSWORD="${DB_PASSWORD}"
    fi

    # Create test DB
    psql -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d postgres \
        -c "DROP DATABASE IF EXISTS ${test_db};" 2>/dev/null
    psql -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d postgres \
        -c "CREATE DATABASE ${test_db};" 2>/dev/null

    # Restore
    if pg_restore -d "${test_db}" -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" \
        --no-owner --no-privileges "${last_pg_dump}" 2>>"${LOG_DIR}/backup.log"; then
        info "  [OK] Restore test successful"
    else
        error "  [FAIL] Restore test FAILED"
    fi

    # Cleanup
    psql -U "${DB_USER}" -h "${DB_HOST}" -p "${DB_PORT}" -d postgres \
        -c "DROP DATABASE IF EXISTS ${test_db};" 2>/dev/null
    unset PGPASSWORD
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="${1:-}"

    case "${mode}" in
        --verify)
            verify_backup
            ;;
        --test-restore)
            test_restore
            ;;
        --help|-h)
            echo "Usage: bash backup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (none)            Run backup and rotation"
            echo "  --verify           Verify last backup integrity"
            echo "  --test-restore     Test restore to temporary DB"
            ;;
        *)
            backup_postgresql
            backup_valkey
            rotate_backups
            remote_sync
            info "Backup complete"
            ;;
    esac
}

main "$@"
