#!/usr/bin/env bash
#
# deploy-cn.sh - 国内一键部署脚本 (China domestic deployment)
# Supports: Ubuntu 22.04+ (APT), CentOS 8+ / RHEL 8+ (DNF)
# All mirrors configured for China network:
#   APT/DNF: Aliyun | PyPI: Aliyun | PostgreSQL: Official | Valkey: Gitee mirror (source)
#   Nginx: Aliyun | Python source: Huawei Cloud
# Usage:
#   sudo bash deploy-cn.sh                    # Fresh install
#   sudo bash deploy-cn.sh --update           # Update from latest release
#   sudo bash deploy-cn.sh --rollback <tag>   # Rollback to a specific release
#
# Self-clean: remove Windows CRLF line endings that break heredocs
if [[ -f "$0" ]]; then
    if grep -qP '\r' "$0" 2>/dev/null; then
        sed -i 's/\r$//' "$0"
    fi
fi

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_NAME="sales-ops"
APP_DIR="/opt/sales-ops"
INSTALL_DIR="${APP_DIR}/releases"
CURRENT_LINK="${APP_DIR}/current"
FRONTEND_DIST_DIR="${APP_DIR}/frontend-dist"
LOG_DIR="${APP_DIR}/logs"
SOCKET_DIR="/var/run/${APP_NAME}"
VERSION_MANIFEST="${APP_DIR}/.versions"

# Database defaults
DB_NAME="${DB_NAME:-salesops}"
DB_USER="${DB_USER:-salesops}"
DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -hex 24)}"
DB_HOST="/var/run/postgresql"
DB_PORT="5432"

# Valkey defaults
VALKEY_SOCK_DIR="/var/run/valkey"
VALKEY_PASSWORD="${VALKEY_PASSWORD:-$(openssl rand -hex 24)}"
VALKEY_CACHE_DB="0"
VALKEY_BROKER_DB="1"
VALKEY_SESSION_DB="2"

# Nginx HTTPS port
HTTPS_PORT="8089"

# Django
DJANGO_SECRET_KEY="${DJANGO_SECRET_KEY:-$(openssl rand -hex 50)}"
ALLOWED_HOSTS="${ALLOWED_HOSTS:-$(hostname -f),$(hostname),localhost,127.0.0.1}"
SECURE_SSL_REDIRECT="True"
SESSION_COOKIE_SECURE="True"
CSRF_COOKIE_SECURE="True"

# Gitee (China mirror of GitHub)
GITEE_OWNER="${GITEE_OWNER:-wxbns}"
GITEE_REPO="${GITEE_REPO:-sales-operations-platform}"

# PostgreSQL pinned version (major only, no version pinning)
PG_MAJOR="18"
PG_VERSION="${PG_MAJOR}"

# Valkey pinned version
VALKEY_VERSION="9.1.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Utility: Require root
# ---------------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Use: sudo bash deploy-cn.sh"
    fi
}

# ---------------------------------------------------------------------------
# Utility: Detect OS and package manager
# ---------------------------------------------------------------------------
detect_os() {
    info "Detecting operating system..."
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID}"
        OS_VERSION_ID="${VERSION_ID}"
        OS_NAME="${PRETTY_NAME}"
    else
        die "Cannot detect OS. Only Ubuntu 22.04+ and CentOS 8+ are supported."
    fi

    case "${OS_ID}" in
        ubuntu)
            if [[ ${OS_VERSION_ID%%.*} -lt 22 ]]; then
                die "Ubuntu 22.04 or later is required. Detected: ${OS_NAME}"
            fi
            PKG_MANAGER="apt"
            info "Detected: ${OS_NAME} (APT)"
            ;;
        centos|rhel|rocky|almalinux)
            major="${OS_VERSION_ID%%.*}"
            if [[ ${major} -lt 8 ]]; then
                die "CentOS/RHEL 8 or later is required. Detected: ${OS_NAME}"
            fi
            PKG_MANAGER="dnf"
            info "Detected: ${OS_NAME} (DNF)"
            ;;
        debian)
            PKG_MANAGER="apt"
            info "Detected: ${OS_NAME} (APT)"
            ;;
        *)
            die "Unsupported OS: ${OS_NAME}. Only Ubuntu 22.04+ and CentOS 8+ are supported."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Utility: Package install wrapper
# ---------------------------------------------------------------------------
pkg_install() {
    local packages=("$@")
    case "${PKG_MANAGER}" in
        apt)
            apt-get update -qq
            apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
    esac
}

pkg_install_no_update() {
    local packages=("$@")
    case "${PKG_MANAGER}" in
        apt)
            apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# New: Configure domestic mirrors for China
# ---------------------------------------------------------------------------
configure_mirrors() {
    info "Configuring domestic mirrors for system packages..."

    case "${PKG_MANAGER}" in
        apt)
            if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
                # DEB822 format (Ubuntu 24.04+)
                cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak
                sed -i 's|^URIs: http://archive.ubuntu.com/ubuntu|URIs: https://mirrors.aliyun.com/ubuntu|' /etc/apt/sources.list.d/ubuntu.sources
                sed -i 's|^URIs: http://security.ubuntu.com/ubuntu|URIs: https://mirrors.aliyun.com/ubuntu|' /etc/apt/sources.list.d/ubuntu.sources
                # Clear legacy sources.list to avoid duplicates
                if [[ -f /etc/apt/sources.list ]]; then
                    cp /etc/apt/sources.list /etc/apt/sources.list.bak
                    > /etc/apt/sources.list
                fi
                info "APT sources configured (Aliyun mirror, DEB822 format)"
            else
                # Legacy format
                cp /etc/apt/sources.list /etc/apt/sources.list.bak
                local codename
                codename=$(lsb_release -cs)
                cat > /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/ubuntu ${codename} main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu ${codename}-security main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu ${codename}-updates main restricted universe multiverse
EOF
                info "APT sources configured (Aliyun mirror, legacy format)"
            fi
            ;;
        dnf)
            # CentOS/RHEL: use Aliyun
            sed -i 's|^mirrorlist=|#mirrorlist=|' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
            sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
            info "DNF sources configured (Aliyun mirror)"
            ;;
    esac

    info "Domestic mirrors configured"
}

# ---------------------------------------------------------------------------
# New: Configure pip domestic mirror (Aliyun)
# ---------------------------------------------------------------------------
configure_pip_mirror() {
    info "Configuring pip domestic mirror (Aliyun)..."

    mkdir -p /etc/pip
    cat > /etc/pip/pip.conf <<'EOF'
[global]
index-url = https://mirrors.aliyun.com/pypi/simple
trusted-host = mirrors.aliyun.com
EOF

    # Also configure for app_user
    local app_home
    app_home=$(eval echo ~app_user)
    mkdir -p "${app_home}/.config/pip"
    cat > "${app_home}/.config/pip/pip.conf" <<'EOF'
[global]
index-url = https://mirrors.aliyun.com/pypi/simple
trusted-host = mirrors.aliyun.com
EOF
    chown -R app_user:app_user "${app_home}/.config/pip"

    info "Pip mirror configured"
}

# ---------------------------------------------------------------------------
# Step 0: Create application directories
# ---------------------------------------------------------------------------
create_dirs() {
    info "Creating application directories..."
    mkdir -p "${APP_DIR}" "${INSTALL_DIR}" "${FRONTEND_DIST_DIR}" "${LOG_DIR}" \
             "${SOCKET_DIR}" "${VALKEY_SOCK_DIR}"
    chown app_user:app_user "${APP_DIR}" "${INSTALL_DIR}" "${LOG_DIR}"
    chown app_user:app_user "${SOCKET_DIR}"
    mkdir -p /opt/sales-ops/backend/logs
}

# ---------------------------------------------------------------------------
# Step 1: Create service users (Principle of Least Privilege)
# ---------------------------------------------------------------------------
create_service_users() {
    info "Creating service users..."

    # app_user: runs Django/Uvicorn
    if ! id app_user &>/dev/null; then
        useradd -r -m -d /opt/sales-ops -s /usr/sbin/nologin -c "Sales Ops Application" app_user
        info "Created user: app_user"
    else
        info "User app_user already exists"
    fi

    # celery_user: runs Celery workers
    if ! id celery_user &>/dev/null; then
        useradd -r -m -d /opt/sales-ops/celery -s /usr/sbin/nologin -c "Sales Ops Celery" celery_user
        info "Created user: celery_user"
    else
        info "User celery_user already exists"
    fi

    # Add celery_user to app_user group for shared file access
    usermod -aG app_user celery_user
}

# ---------------------------------------------------------------------------
# Step 2: Install PostgreSQL 18 from official repository
# ---------------------------------------------------------------------------
install_postgresql() {
    info "Installing PostgreSQL ${PG_MAJOR}..."

    if command -v psql &>/dev/null && psql --version | grep -q "psql (PostgreSQL) ${PG_MAJOR}"; then
        info "PostgreSQL ${PG_MAJOR} already installed"
        return
    fi

    case "${PKG_MANAGER}" in
        apt)
            # Install PostgreSQL apt repository (official apt.postgresql.org)
            pkg_install_no_update curl ca-certificates gnupg lsb-release
            curl -fSL --connect-timeout 30 https://www.postgresql.org/media/keys/ACCC4CF8.asc \
                | gpg --batch --yes --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] \
http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
                > /etc/apt/sources.list.d/pgdg.list
            apt-get update -qq
            # Install without version pin (use major version only)
            apt-get install -y "postgresql-${PG_MAJOR}" "postgresql-client-${PG_MAJOR}"
            ;;
        dnf)
            # Install PostgreSQL yum repository
            pkg_install_no_update curl
            dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm --eval '%rhel')-x86_64/pgdg-redhat-repo-latest.noarch.rpm
            dnf -qy module disable postgresql
            dnf install -y "postgresql${PG_MAJOR}-server" "postgresql${PG_MAJOR}-contrib"
            ;;
    esac

    # Ensure service is enabled and started
    systemctl enable postgresql
    systemctl start postgresql

    # Record version
    echo "postgresql=${PG_MAJOR}" >> "${VERSION_MANIFEST}"
    info "PostgreSQL ${PG_MAJOR} installed"
}

# ---------------------------------------------------------------------------
# Step 3: Configure PostgreSQL
# ---------------------------------------------------------------------------
configure_postgresql() {
    info "Configuring PostgreSQL..."

    # Initialize if not already
    if [[ "${PKG_MANAGER}" == "dnf" ]]; then
        PG_DATA_DIR="/var/lib/pgsql/${PG_MAJOR}/data"
        if [[ ! -f "${PG_DATA_DIR}/PG_VERSION" ]]; then
            sudo -u postgres /usr/pgsql-${PG_MAJOR}/bin/initdb -D "${PG_DATA_DIR}"
        fi
    fi

    # Create database and user
    sudo -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
        sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
    sudo -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
        sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
    sudo -u postgres psql -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};"

    info "PostgreSQL database '${DB_NAME}' and user '${DB_USER}' configured"
}

# ---------------------------------------------------------------------------
# Step 4: Install Valkey from source (China mirrors)
# ---------------------------------------------------------------------------
install_valkey() {
    info "Installing Valkey ${VALKEY_VERSION} (source build)..."

    # Fully installed check: binary + systemd + config
    if [[ -f /usr/local/bin/valkey-server ]] && \
       [[ -f /etc/valkey/valkey.conf ]] && \
       systemctl -q is-enabled valkey-server 2>/dev/null; then
        info "Valkey ${VALKEY_VERSION} already installed and configured"
        return
    fi

    # Skip compile if binary already exists
    local need_compile=true
    if [[ -f /usr/local/bin/valkey-server ]]; then
        info "Valkey binary found, skipping compile (reconfiguring only)"
        need_compile=false
    fi

    if [[ "${need_compile}" == "true" ]]; then
        # Install build deps
        pkg_install_no_update build-essential pkg-config

        # Download from Gitee mirror with GitHub fallback
        local tarball="/tmp/valkey-${VALKEY_VERSION}.tar.gz"
        curl -fSL --connect-timeout 30 --max-time 300 \
            "https://gitee.com/mirrors/Valkey/archive/refs/tags/${VALKEY_VERSION}.tar.gz" \
            -o "${tarball}" || {
            warn "Gitee mirror failed, trying GitHub..."
            curl -fSL --connect-timeout 30 --max-time 300 \
                "https://github.com/valkey-io/valkey/archive/refs/tags/${VALKEY_VERSION}.tar.gz" \
                -o "${tarball}" || die "Failed to download Valkey source"
        }

        # Validate tarball
        file "${tarball}" | grep -qi "gzip\|tar" || die "Downloaded file is not a valid tarball"

        # Extract to separate build dir (NOT /tmp/valkey-* which would match tarball name)
        local build_dir="/tmp/valkey-build-${VALKEY_VERSION}"
        rm -rf "${build_dir}"
        mkdir -p "${build_dir}"
        tar -xzf "${tarball}" -C "${build_dir}" --strip-components=1

        [[ -f "${build_dir}/src/Makefile" ]] || die "Missing Makefile after extraction"

        cd "${build_dir}"
        make -j"$(nproc)" BUILD_TLS=no 2>&1 | tail -5 || die "Valkey compilation failed"
        make install PREFIX=/usr/local
        cd /

        # Cleanup (tarball is local to this block)
        rm -rf "${build_dir}" "${tarball}"
    fi

    # Create valkey user (if not exists)
    if ! id valkey &>/dev/null; then
        useradd -r -m -d /var/lib/valkey -s /usr/sbin/nologin valkey
    fi

    # Create directories
    mkdir -p /etc/valkey /var/lib/valkey /var/log/valkey "${VALKEY_SOCK_DIR}"
    chown -R valkey:valkey /var/lib/valkey /var/log/valkey

    # Create systemd service
    cat > /etc/systemd/system/valkey-server.service <<'EOF'
[Unit]
Description=Valkey In-Memory Data Store
After=network.target

[Service]
Type=notify
User=valkey
Group=valkey
ExecStart=/usr/local/bin/valkey-server /etc/valkey/valkey.conf
ExecStop=/usr/local/bin/valkey-cli -p 6379 shutdown
Restart=always
RestartSec=3
LimitNOFILE=65535
RuntimeDirectory=valkey
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

    # Create valkey.conf
    local valkey_conf="/etc/valkey/valkey.conf"
    cat > "${valkey_conf}" <<'VAKEY_EOF'
# Valkey configuration - Sales Operations Platform
# Generated by deploy-cn.sh

bind 0.0.0.0 -
protected-mode yes
port 0
unixsocket /var/run/valkey/valkey.sock
unixsocketperm 770

# Per-database ACLs
# User "cache_user" can only access db 0 (cache)
# User "celery_user" can only access db 1 (broker)
# User "session_user" can only access db 2 (sessions)
aclfile /etc/valkey/users.acl

# Memory (will be tuned by deploy-cn.sh based on total RAM)
# maxmemory is set dynamically below

# Persistence
save 900 1
save 300 10
save 60 10000
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/lib/valkey

# Logging
log-level notice
log-format json
logfile /var/log/valkey/valkey.log

# Security
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command DEBUG ""
rename-command CONFIG ""

# Client limits
maxclients 10000
timeout 300
tcp-keepalive 60
VAKEY_EOF

    # Create ACL file
    cat > /etc/valkey/users.acl <<ACL_EOF
user cache_user on >${VALKEY_PASSWORD} ~* +@all -@dangerous -select|12 -select|11 -select|10 -select|9 -select|8 -select|7 -select|6 -select|5 -select|4 -select|3 -select|2 -select|1
user celery_user on >${VALKEY_PASSWORD} ~* +@all -@dangerous -select|12 -select|11 -select|10 -select|9 -select|8 -select|7 -select|6 -select|5 -select|4 -select|3 -select|2 -select|0
user session_user on >${VALKEY_PASSWORD} ~* +@all -@dangerous -select|12 -select|11 -select|10 -select|9 -select|8 -select|7 -select|6 -select|5 -select|4 -select|3 -select|1 -select|0
user default off
ACL_EOF

    # Fix ownership and permissions
    chown -R valkey:valkey /etc/valkey
    chmod 640 /etc/valkey/users.acl
    chown -R valkey:valkey /var/lib/valkey /var/log/valkey
    chmod 770 "${VALKEY_SOCK_DIR}"

    # Ensure valkey user can write to socket dir
    usermod -aG app_user valkey

    systemctl daemon-reload
    systemctl enable valkey-server
    systemctl start valkey-server

    echo "valkey=${VALKEY_VERSION}" >> "${VERSION_MANIFEST}"
    info "Valkey ${VALKEY_VERSION} installed with per-db ACLs (source build)"
}

# ---------------------------------------------------------------------------
# Step 5: Install Nginx from Aliyun mirror
# ---------------------------------------------------------------------------
install_nginx() {
    info "Installing Nginx..."

    if command -v nginx &>/dev/null && nginx -v 2>&1 | grep -q "nginx version"; then
        info "Nginx already installed"
        return
    fi

    case "${PKG_MANAGER}" in
        apt)
            pkg_install_no_update curl ca-certificates gnupg lsb-release
            # Use official nginx.org repo (directly accessible from China)
            curl -fSL --connect-timeout 30 https://nginx.org/keys/nginx_signing.key \
                | gpg --batch --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg \
                || warn "Nginx GPG key download failed, proceeding without verification"
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
                > /etc/apt/sources.list.d/nginx.list
            echo "Package: *\nPin: origin nginx.org\nPin-Priority: 900\n" \
                > /etc/apt/preferences.d/99nginx
            apt-get update -qq
            apt-get install -y nginx
            ;;
        dnf)
            cat > /etc/yum.repos.d/nginx.repo <<'NGINX_REPO'
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
enabled=1
gpgcheck=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
NGINX_REPO
            dnf install -y nginx
            ;;
    esac

    systemctl enable nginx
    info "Nginx installed"
}

# ---------------------------------------------------------------------------
# Step 5b: Configure Nginx (HTTPS on port 8089 + reverse proxy)
# ---------------------------------------------------------------------------
configure_nginx() {
    info "Configuring Nginx (HTTPS on port ${HTTPS_PORT})..."

    # Generate self-signed SSL certificate (valid 365 days)
    local ssl_dir="/etc/nginx/ssl"
    mkdir -p "${ssl_dir}"
    if [[ ! -f "${ssl_dir}/server.crt" ]]; then
        openssl req -x509 -nodes -days 365 \
            -newkey rsa:2048 \
            -keyout "${ssl_dir}/server.key" \
            -out "${ssl_dir}/server.crt" \
            -subj "/C=CN/ST=Shanghai/L=Shanghai/O=SalesOps/CN=$(hostname -f)" \
            2>/dev/null
        info "Self-signed SSL certificate generated (${ssl_dir})"
    fi

    # Remove default site config
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    # Create sales-ops Nginx config
    local nginx_conf="/etc/nginx/conf.d/sales-ops.conf"
    cat > "${nginx_conf}" <<'NGINX_CONF'
# Sales Operations Platform - Nginx config (generated by deploy-cn.sh)
# HTTPS on custom port, reverse proxy to Uvicorn socket

# Upstream via Unix socket
upstream sales_ops_backend {
    server unix:/var/run/sales-ops/app.sock fail_timeout=0;
}

# HTTP -> redirect to HTTPS (port 8089)
server {
    listen 80;
    server_name _;
    return 301 https://$host:__HTTPS_PORT__$request_uri;
}

# HTTPS server
server {
    listen __HTTPS_PORT__ ssl;
    server_name _;

    # SSL
    ssl_certificate     /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5:!RC4;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript;

    # Client max body size (file uploads)
    client_max_body_size 50m;

    # Static files (served directly by Nginx)
    location /static/ {
        alias /opt/sales-ops/frontend-dist/;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    # Media files
    location /media/ {
        alias /opt/sales-ops/current/backend/media/;
        expires 7d;
    }

    # Django admin media
    location /static/admin/ {
        alias /opt/sales-ops/current/backend/staticfiles/admin/;
    }

    # Reverse proxy to Uvicorn
    location / {
        proxy_pass http://sales_ops_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host:$server_port;
        proxy_redirect off;
        proxy_buffering on;
        proxy_connect_timeout 30s;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        proxy_buffers 8 16k;
        proxy_buffer_size 32k;
    }

    # Health check endpoint (bypass proxy)
    location /health {
        access_log off;
        return 200 "OK";
        add_header Content-Type text/plain;
    }

    # Deny hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Logging
    access_log /var/log/nginx/sales-ops-access.log;
    error_log  /var/log/nginx/sales-ops-error.log;
}
NGINX_CONF

    # Replace placeholder with actual port
    sed -i "s/__HTTPS_PORT__/${HTTPS_PORT}/g" "${nginx_conf}"

    # Verify Nginx config
    if nginx -t 2>&1; then
        info "Nginx config verified OK"
    else
        error "Nginx config verification failed!"
        return 1
    fi

    info "Nginx configured: HTTP(:80) -> HTTPS(:${HTTPS_PORT}), reverse proxy to Uvicorn"
}

# ---------------------------------------------------------------------------
# Step 6: Install Python 3.13
# ---------------------------------------------------------------------------
install_python() {
    info "Installing Python 3.13..."

    if command -v python3.13 &>/dev/null; then
        info "Python 3.13 already installed"
        return
    fi

    case "${PKG_MANAGER}" in
        apt)
            pkg_install software-properties-common
            add-apt-repository -y ppa:deadsnakes/ppa
            apt-get update -qq
            pkg_install_no_update python3.13 python3.13-venv python3.13-dev
            ;;
        dnf)
            pkg_install_no_update gcc make zlib-devel bzip2-devel readline-devel \
                sqlite-devel openssl-devel tk-devel libffi-devel xz-devel
            # Use Huawei Cloud mirror for Python source
            curl -fSL --connect-timeout 30 --max-time 300 \
                "https://mirrors.huaweicloud.com/python/3.13.0/Python-3.13.0.tgz" \
                -o /tmp/Python-3.13.0.tgz
            tar -xzf /tmp/Python-3.13.0.tgz -C /tmp
            cd /tmp/Python-3.13.0
            ./configure --enable-optimizations --prefix=/usr/local --with-ensurepip=install
            make -j"$(nproc)"
            make altinstall
            ln -sf /usr/local/bin/python3.13 /usr/local/bin/python3
            ln -sf /usr/local/bin/pip3.13 /usr/local/bin/pip3
            cd /
            rm -rf /tmp/Python-3.13.0 /tmp/Python-3.13.0.tgz
            ;;
    esac

    echo "python=$(python3.13 --version 2>&1)" >> "${VERSION_MANIFEST}"
    info "Python 3.13 installed"
}

# ---------------------------------------------------------------------------
# Step 7: Clone application from Gitee发行库
# ---------------------------------------------------------------------------
pull_release() {
    local tag="${1:-main}"

    info "Cloning application from Gitee发行库 (branch: ${tag})..."

    # If already cloned, just pull latest
    if [[ -d "${CURRENT_LINK}/.git" ]]; then
        info "Application repo already exists, pulling latest..."
        cd "${CURRENT_LINK}"
        git pull --ff-only 2>/dev/null || warn "git pull failed, using existing files"
        cd /
        return
    fi

    mkdir -p "${INSTALL_DIR}"

    # Clone发行库 (contains built frontend + backend)
    local release_dir="${INSTALL_DIR}/current"
    if [[ -d "${release_dir}" ]]; then
        rm -rf "${release_dir}"
    fi

    pkg_install_no_update git

    # Try Gitee first, fallback to GitHub
    git clone --depth 1 --branch "${tag}" \
        "https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}.git" \
        "${release_dir}" 2>/dev/null || {
        warn "Gitee clone failed, trying GitHub..."
        git clone --depth 1 --branch "${tag}" \
            "https://github.com/${GITEE_OWNER}/${GITEE_REPO}.git" \
            "${release_dir}" 2>/dev/null || \
            die "Failed to clone from both Gitee and GitHub"
    }

    # Symlink current
    ln -sfn "${release_dir}" "${CURRENT_LINK}"

    # Locate backend and frontend directories within the repo
    # The repo structure: backend/ contains Django code, frontend/ contains built static files
    local backend_check="${CURRENT_LINK}/backend/manage.py"
    local frontend_check="${CURRENT_LINK}/frontend/index.html"

    if [[ ! -f "${backend_check}" ]]; then
        warn "backend/manage.py not found at ${CURRENT_LINK}/backend/"
        warn "The发行库 may not contain the expected directory structure"
    fi
    if [[ ! -f "${frontend_check}" ]]; then
        warn "frontend/index.html not found at ${CURRENT_LINK}/frontend/"
        warn "Frontend static files may not be present"
    fi

    echo "release=$(cd "${release_dir}" && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')" >> "${VERSION_MANIFEST}"
    info "Application cloned to ${release_dir}"
}

# ---------------------------------------------------------------------------
# Step 8: Create virtual environment and install dependencies
# ---------------------------------------------------------------------------
setup_venv() {
    info "Setting up Python virtual environment..."

    local venv_dir="${APP_DIR}/venv"

    if [[ -d "${venv_dir}" ]]; then
        info "Virtual environment already exists"
    else
        python3.13 -m venv "${venv_dir}"
        info "Created virtual environment at ${venv_dir}"
    fi

    # Install dependencies with --require-hashes
    if [[ -f "${CURRENT_LINK}/backend/requirements.txt" ]]; then
        "${venv_dir}/bin/pip" install --upgrade pip setuptools wheel
        "${venv_dir}/bin/pip" install --require-hashes \
            -r "${CURRENT_LINK}/backend/requirements.txt"
        info "Python dependencies installed (--require-hashes, Aliyun PyPI mirror)"
    else
        warn "requirements.txt not found, skipping pip install"
    fi
}

# ---------------------------------------------------------------------------
# Step 9: Generate local_settings.py from template
# ---------------------------------------------------------------------------
generate_local_settings() {
    info "Generating local_settings.py..."

    local template="${CURRENT_LINK}/deploy/local_settings.py.template"
    local output="${CURRENT_LINK}/backend/config/settings/local_settings.py"

    if [[ ! -f "${template}" ]]; then
        warn "Template not found at ${template}, generating inline..."
        # Inline template if repo template not present
        template=""
    fi

    mkdir -p "$(dirname "${output}")"

    if [[ -n "${template}" && -f "${template}" ]]; then
        sed \
            -e "s|{{DB_NAME}}|${DB_NAME}|g" \
            -e "s|{{DB_USER}}|${DB_USER}|g" \
            -e "s|{{DB_PASSWORD}}|${DB_PASSWORD}|g" \
            -e "s|{{DB_HOST}}|${DB_HOST}|g" \
            -e "s|{{DB_PORT}}|${DB_PORT}|g" \
            -e "s|{{VALKEY_HOST}}|${VALKEY_SOCK_DIR}|g" \
            -e "s|{{VALKEY_PASSWORD}}|${VALKEY_PASSWORD}|g" \
            -e "s|{{VALKEY_CACHE_DB}}|${VALKEY_CACHE_DB}|g" \
            -e "s|{{VALKEY_BROKER_DB}}|${VALKEY_BROKER_DB}|g" \
            -e "s|{{VALKEY_SESSION_DB}}|${VALKEY_SESSION_DB}|g" \
            -e "s|{{SECRET_KEY}}|${DJANGO_SECRET_KEY}|g" \
            -e "s|{{ALLOWED_HOSTS}}|${ALLOWED_HOSTS}|g" \
            -e "s|{{SECURE_SSL_REDIRECT}}|${SECURE_SSL_REDIRECT}|g" \
            -e "s|{{SESSION_COOKIE_SECURE}}|${SESSION_COOKIE_SECURE}|g" \
            -e "s|{{CSRF_COOKIE_SECURE}}|${CSRF_COOKIE_SECURE}|g" \
            "${template}" > "${output}"
    else
        # Generate directly
        cat > "${output}" <<SETTINGS_EOF
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = os.environ.get('DJANGO_SECRET_KEY', '${DJANGO_SECRET_KEY}')
DEBUG = False
ALLOWED_HOSTS = ['${ALLOWED_HOSTS//,/\',\'}']

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': '${DB_NAME}',
        'USER': '${DB_USER}',
        'PASSWORD': '${DB_PASSWORD}',
        'HOST': '${DB_HOST}',
        'PORT': '${DB_PORT}',
        'CONN_MAX_AGE': 60,
        'OPTIONS': {'connect_timeout': 10},
    }
}

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.valkey.ValkeyCache',
        'LOCATION': 'unix://${VALKEY_SOCK_DIR}/valkey.sock?db=${VALKEY_CACHE_DB}',
        'KEY_PREFIX': 'salesops',
        'TIMEOUT': 300,
        'OPTIONS': {
            'PASSWORD': '${VALKEY_PASSWORD}',
            'CLIENT_CLASS': 'django_valkey.client.DefaultClient',
        },
    }
}

CELERY_BROKER_URL = 'unix://${VALKEY_SOCK_DIR}/valkey.sock?virtual_host=${VALKEY_BROKER_DB}'
CELERY_RESULT_BACKEND = 'unix://${VALKEY_SOCK_DIR}/valkey.sock?virtual_host=${VALKEY_BROKER_DB}'

SESSION_ENGINE = 'django.contrib.sessions.backends.cache'
SESSION_CACHE_ALIAS = 'sessions'

CACHES['sessions'] = {
    'BACKEND': 'django.core.cache.backends.valkey.ValkeyCache',
    'LOCATION': 'unix://${VALKEY_SOCK_DIR}/valkey.sock?db=${VALKEY_SESSION_DB}',
    'KEY_PREFIX': 'salesops_sess',
    'TIMEOUT': 86400 * 7,
    'OPTIONS': {
        'PASSWORD': '${VALKEY_PASSWORD}',
        'CLIENT_CLASS': 'django_valkey.client.DefaultClient',
    },
}

STATIC_ROOT = BASE_DIR / 'staticfiles'
MEDIA_ROOT = BASE_DIR / 'media'
MEDIA_URL = '/media/'

SECURE_SSL_REDIRECT = ${SECURE_SSL_REDIRECT}
SESSION_COOKIE_SECURE = ${SESSION_COOKIE_SECURE}
CSRF_COOKIE_SECURE = ${CSRF_COOKIE_SECURE}

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {'console': {'class': 'logging.StreamHandler'}},
    'root': {'handlers': ['console'], 'level': 'INFO'},
    'loggers': {
        'django': {'handlers': ['console'], 'level': 'INFO', 'propagate': False},
    },
}
SETTINGS_EOF
    fi

    # Create .env file for systemd EnvironmentFile
    cat > "${CURRENT_LINK}/backend/.env" <<ENV_EOF
DJANGO_SETTINGS_MODULE=config.settings.local
DJANGO_SECRET_KEY=${DJANGO_SECRET_KEY}
DATABASE_URL=postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}
VALKEY_URL=unix://${VALKEY_SOCK_DIR}/valkey.sock?db=${VALKEY_CACHE_DB}
CELERY_BROKER_URL=unix://${VALKEY_SOCK_DIR}/valkey.sock?virtual_host=${VALKEY_BROKER_DB}
ENV_EOF

    chmod 640 "${output}" "${CURRENT_LINK}/backend/.env"
    chown app_user:app_user "${output}" "${CURRENT_LINK}/backend/.env"
    info "local_settings.py generated at ${output}"
}

# ---------------------------------------------------------------------------
# Step 10: Django migrate + collectstatic
# ---------------------------------------------------------------------------
django_setup() {
    info "Running Django migrations and collectstatic..."

    local backend_dir="${CURRENT_LINK}/backend"

    # Migrate
    sudo -u app_user DJANGO_SETTINGS_MODULE=config.settings.local \
        "${APP_DIR}/venv/bin/python" "${backend_dir}/manage.py" migrate --no-input

    # Collect static
    sudo -u app_user DJANGO_SETTINGS_MODULE=config.settings.local \
        "${APP_DIR}/venv/bin/python" "${backend_dir}/manage.py" collectstatic --no-input

    # NOTE: Superuser creation is now handled by the web-based Setup Wizard.
    # After deployment, visit http://$(hostname -f)/setup to initialize the system.

    info "Django setup complete"
}

# ---------------------------------------------------------------------------
# Step 11: Deploy frontend
# ---------------------------------------------------------------------------
deploy_frontend() {
    info "Deploying frontend static files..."

    rm -rf "${FRONTEND_DIST_DIR:?}"/*
    cp -r "${CURRENT_LINK}/frontend/"* "${FRONTEND_DIST_DIR}/"

    chown -R www-data:www-data "${FRONTEND_DIST_DIR}"
    info "Frontend deployed to ${FRONTEND_DIST_DIR}"
}

# ---------------------------------------------------------------------------
# Step 12: Install systemd service files
# ---------------------------------------------------------------------------
install_systemd_services() {
    info "Installing systemd service files..."

    # Determine venv path for ExecStart (may be symlinked)
    local venv_bin="${APP_DIR}/venv/bin"
    local backend_dir="${CURRENT_LINK}/backend"

    # Detect CPU count for Uvicorn workers
    local workers
    workers=$(python3 -c "import os; print(max(2, min(8, os.cpu_count() or 4)))")

    # sales-ops-backend.service
    cat > /etc/systemd/system/sales-ops-backend.service <<EOF
[Unit]
Description=Sales Ops Backend (Uvicorn)
After=postgresql.service valkey-server.service network.target
Wants=postgresql.service valkey-server.service

[Service]
Type=notify
User=app_user
Group=app_user
WorkingDirectory=${backend_dir}
ExecStart=${venv_bin}/uvicorn config.wsgi:application \
    --socket ${SOCKET_DIR}/app.sock \
    --workers ${workers} \
    --access-log - \
    --log-level info \
    --timeout-keep-alive 5
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=always
RestartSec=5
MemoryMax=2G
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sales-ops-backend
EnvironmentFile=${backend_dir}/.env

[Install]
WantedBy=multi-user.target
EOF

    # sales-ops-celery.service
    cat > /etc/systemd/system/sales-ops-celery.service <<EOF
[Unit]
Description=Sales Ops Celery Worker
After=postgresql.service valkey-server.service network.target
Wants=postgresql.service valkey-server.service

[Service]
Type=simple
User=celery_user
Group=celery_user
WorkingDirectory=${backend_dir}
ExecStart=${venv_bin}/celery -A config worker \
    --loglevel=info \
    --concurrency=4 \
    --max-tasks-per-child=1000 \
    --time-limit=300 \
    --soft-time-limit=240
Restart=always
RestartSec=10
MemoryMax=4G
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sales-ops-celery
EnvironmentFile=${backend_dir}/.env

[Install]
WantedBy=multi-user.target
EOF

    # sales-ops-celery-beat.service
    cat > /etc/systemd/system/sales-ops-celery-beat.service <<EOF
[Unit]
Description=Sales Ops Celery Beat (Scheduler)
After=postgresql.service valkey-server.service network.target
Wants=postgresql.service valkey-server.service

[Service]
Type=simple
User=celery_user
Group=celery_user
WorkingDirectory=${backend_dir}
ExecStart=${venv_bin}/celery -A config beat \
    --loglevel=info \
    --pidfile=${SOCKET_DIR}/celery-beat.pid
Restart=always
RestartSec=10
MemoryMax=512M
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sales-ops-celery-beat
EnvironmentFile=${backend_dir}/.env

[Install]
WantedBy=multi-user.target
EOF

    # Set permissions on socket dir
    chmod 775 "${SOCKET_DIR}"
    setfacl -m u:www-data:rx "${SOCKET_DIR}" 2>/dev/null || true

    systemctl daemon-reload
    info "Systemd service files installed"
}

# ---------------------------------------------------------------------------
# Step 13: Install logrotate config
# ---------------------------------------------------------------------------
install_logrotate() {
    info "Installing logrotate configuration..."

    cat > /etc/logrotate.d/sales-ops <<'LOGROTATE_EOF'
/opt/sales-ops/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 app_user app_user
    sharedscripts
    postrotate
        systemctl reload sales-ops-backend > /dev/null 2>&1 || true
    endscript
}

/var/log/nginx/sales-ops-access.log
/var/log/nginx/sales-ops-error.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
LOGROTATE_EOF

    info "Logrotate config installed"
}

# ---------------------------------------------------------------------------
# Step 14: Memory tuning (auto-detect RAM)
# ---------------------------------------------------------------------------
memory_tuning() {
    info "Auto-detecting memory and tuning..."

    local total_ram_gb
    total_ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    local total_ram_kb
    total_ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)

    info "Total RAM: ${total_ram_gb}GB"

    if [[ ${total_ram_gb} -lt 1 ]]; then
        warn "Less than 1GB RAM detected. Tuning values may be too conservative."
    fi

    # PostgreSQL shared_buffers = 30% of RAM
    local pg_shared_buffers_mb=$((total_ram_gb * 307))
    if [[ ${pg_shared_buffers_mb} -gt 16384 ]]; then
        pg_shared_buffers_mb=16384  # Cap at 16GB
    fi

    # Valkey maxmemory = 20% of RAM
    local valkey_maxmemory_mb=$((total_ram_gb * 204))
    if [[ ${valkey_maxmemory_mb} -gt 8192 ]]; then
        valkey_maxmemory_mb=8192  # Cap at 8GB
    fi

    local valkey_maxmemory_bytes=$((valkey_maxmemory_mb * 1024 * 1024))

    # Update Valkey config with memory limit
    local valkey_conf="/etc/valkey/valkey.conf"
    if [[ -f "${valkey_conf}" ]]; then
        sed -i "s/^# maxmemory.*/maxmemory ${valkey_maxmemory_bytes}/" "${valkey_conf}"
        # If no line matched, append
        grep -q "^maxmemory " "${valkey_conf}" || \
            echo "maxmemory ${valkey_maxmemory_bytes}" >> "${valkey_conf}"
        systemctl restart valkey-server
    fi

    # Update PostgreSQL config
    local pg_conf
    if [[ "${PKG_MANAGER}" == "apt" ]]; then
        pg_conf="/etc/postgresql/${PG_MAJOR}/main/postgresql.conf"
    else
        pg_conf="/var/lib/pgsql/${PG_MAJOR}/data/postgresql.conf"
    fi

    if [[ -f "${pg_conf}" ]]; then
        cat >> "${pg_conf}" <<PG_EOF

# --- Sales Ops Platform tuning (auto-generated by deploy-cn.sh) ---
shared_buffers = ${pg_shared_buffers_mb}MB
effective_cache_size = $((total_ram_gb * 230))MB
maintenance_work_mem = $((total_ram_gb * 77))MB
work_mem = 16MB
wal_buffers = 16MB
checkpoint_completion_target = 0.9
max_connections = 100
random_page_cost = 1.1
effective_io_concurrency = 200
min_wal_size = 1GB
max_wal_size = 4GB
huge_pages = try
PG_EOF
        systemctl restart postgresql
    fi

    # Kernel sysctl tuning
    cat > /etc/sysctl.d/99-sales-ops.conf <<SYSCTL_EOF
# Sales Ops Platform kernel tuning (auto-generated by deploy-cn.sh)
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_syn_backlog = 65535
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
SYSCTL_EOF

    sysctl --system > /dev/null 2>&1

    # Record tuning
    cat >> "${VERSION_MANIFEST}" <<VERSION_EOF
pg_shared_buffers=${pg_shared_buffers_mb}MB
valkey_maxmemory=${valkey_maxmemory_mb}MB
ram_total=${total_ram_gb}GB
VERSION_EOF

    info "Memory tuning: PG shared_buffers=${pg_shared_buffers_mb}MB, Valkey maxmemory=${valkey_maxmemory_mb}MB"
}

# ---------------------------------------------------------------------------
# Step 15: Register backup cron
# ---------------------------------------------------------------------------
register_backup_cron() {
    info "Registering backup cron job (daily 02:00)..."

    local cron_entry="0 2 * * * root ${CURRENT_LINK}/scripts/backup.sh >> ${LOG_DIR}/backup.log 2>&1"

    # Remove old entry if exists
    crontab -l 2>/dev/null | grep -v "backup.sh" | { cat; echo "${cron_entry}"; } | crontab -
    info "Backup cron registered"
}

# ---------------------------------------------------------------------------
# Step 16: Register monitor cron
# ---------------------------------------------------------------------------
register_monitor_cron() {
    info "Registering monitor cron job (every 5 minutes)..."

    local cron_entry="*/5 * * * * root ${CURRENT_LINK}/scripts/monitor.sh >> ${LOG_DIR}/monitor.log 2>&1"

    # Remove old entry if exists
    crontab -l 2>/dev/null | grep -v "monitor.sh" | { cat; echo "${cron_entry}"; } | crontab -
    info "Monitor cron registered"
}

# ---------------------------------------------------------------------------
# Step 17: Start all services
# ---------------------------------------------------------------------------
start_services() {
    info "Starting all services..."

    systemctl daemon-reload

    # Enable and start in dependency order
    systemctl enable postgresql
    systemctl enable valkey-server
    systemctl enable sales-ops-backend
    systemctl enable sales-ops-celery
    systemctl enable sales-ops-celery-beat
    systemctl enable nginx

    systemctl restart postgresql
    sleep 2
    systemctl restart valkey-server
    sleep 2
    systemctl restart sales-ops-backend
    sleep 2
    systemctl restart sales-ops-celery
    systemctl restart sales-ops-celery-beat
    sleep 1
    systemctl restart nginx

    # Open firewall for HTTPS port
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "${HTTPS_PORT}/tcp" 2>/dev/null || true
        info "Firewall: opened port ${HTTPS_PORT}/tcp (ufw)"
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${HTTPS_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "Firewall: opened port ${HTTPS_PORT}/tcp (firewalld)"
    fi

    info "All services started"
}

# ---------------------------------------------------------------------------
# Step 18: Health check
# ---------------------------------------------------------------------------
health_check() {
    info "Running health check..."

    local errors=0

    # Check PostgreSQL
    if sudo -u postgres psql -d "${DB_NAME}" -c "SELECT 1" &>/dev/null; then
        info "  [OK] PostgreSQL"
    else
        error "  [FAIL] PostgreSQL"
        errors=$((errors + 1))
    fi

    # Check Valkey
    if /usr/local/bin/valkey-cli -s "${VALKEY_SOCK_DIR}/valkey.sock" -a "${VALKEY_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
        info "  [OK] Valkey"
    else
        error "  [FAIL] Valkey"
        errors=$((errors + 1))
    fi

    # Check Uvicorn socket
    sleep 3
    if [[ -S "${SOCKET_DIR}/app.sock" ]]; then
        info "  [OK] Uvicorn socket"
    else
        error "  [FAIL] Uvicorn socket not found at ${SOCKET_DIR}/app.sock"
        errors=$((errors + 1))
    fi

    # Check Nginx
    if nginx -t 2>/dev/null; then
        info "  [OK] Nginx config"
    else
        error "  [FAIL] Nginx config"
        errors=$((errors + 1))
    fi

    # Check systemd services
    for svc in sales-ops-backend sales-ops-celery sales-ops-celery-beat; do
        if systemctl is-active "${svc}" &>/dev/null; then
            info "  [OK] ${svc}"
        else
            error "  [FAIL] ${svc}"
            errors=$((errors + 1))
        fi
    done

    if [[ ${errors} -gt 0 ]]; then
        error "${errors} service(s) failed health check. Check journalctl for details."
        return 1
    fi

    echo ""
    echo "=============================================="
    echo "  Sales Operations Platform deployed!"
    echo "=============================================="
    echo "  Access: https://$(hostname -f):${HTTPS_PORT}"
    echo "  DB:     ${DB_NAME}@${DB_HOST}"
    echo "  Release: $(cat "${VERSION_MANIFEST}" | grep '^release=' | cut -d= -f2)"
    echo "=============================================="
}

# ---------------------------------------------------------------------------
# Step 19: Print deployment summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "Deployment Summary (deploy-cn.sh):"
    echo "  OS:           ${OS_NAME}"
    echo "  App Dir:      ${APP_DIR}"
    echo "  Release:      $(readlink "${CURRENT_LINK}")"
    echo "  PostgreSQL:   ${PG_MAJOR} (official apt.postgresql.org)"
    echo "  Valkey:       ${VALKEY_VERSION} (source build, Gitee mirror)"
    echo "  Python:       $(python3.13 --version 2>&1)"
    echo "  HTTPS Port:   ${HTTPS_PORT}"
    echo "  Socket Dir:   ${SOCKET_DIR}"
    echo "  Valkey Socket: ${VALKEY_SOCK_DIR}/valkey.sock"
    echo ""
    echo "  Mirrors configured:"
    echo "    APT/DNF:     Aliyun (mirrors.aliyun.com)"
    echo "    PyPI:        Aliyun (mirrors.aliyun.com/pypi/simple)"
    echo "    Nginx:       Official (nginx.org)"
    echo "    Python src:  Huawei Cloud (mirrors.huaweicloud.com)"
    echo "    Valkey src:  Gitee mirror (gitee.com/mirrors/Valkey)"
    echo "    Releases:    Gitee (gitee.com/${GITEE_OWNER}/${GITEE_REPO})"
    echo ""
    echo "Credentials (SAVE THESE):"
    echo "  DB User:      ${DB_USER}"
    echo "  DB Password:  ${DB_PASSWORD}"
    echo "  DB Name:      ${DB_NAME}"
    echo "  Valkey Password: ${VALKEY_PASSWORD}"
    echo "  Django Secret: ${DJANGO_SECRET_KEY}"
    echo ""
    echo "Useful Commands:"
    echo "  View backend logs:  journalctl -u sales-ops-backend -f"
    echo "  View celery logs:   journalctl -u sales-ops-celery -f"
    echo "  View nginx logs:    journalctl -u nginx -f"
    echo "  Update:             sudo bash ${CURRENT_LINK}/scripts/deploy-cn.sh --update"
    echo "  Backup:             sudo bash ${CURRENT_LINK}/scripts/backup.sh"
    echo "  Monitor:            sudo bash ${CURRENT_LINK}/scripts/monitor.sh"
}

# ---------------------------------------------------------------------------
# Update mode: pull latest and redeploy
# ---------------------------------------------------------------------------
do_update() {
    require_root
    info "Starting update mode..."
    detect_os
    pull_release "main"
    setup_venv
    generate_local_settings
    django_setup
    deploy_frontend
    install_systemd_services
    start_services
    health_check
}

# ---------------------------------------------------------------------------
# Rollback mode
# ---------------------------------------------------------------------------
do_rollback() {
    local tag="${1:-}"
    if [[ -z "${tag}" ]]; then
        die "Usage: deploy-cn.sh --rollback <tag>"
    fi

    require_root
    info "Rolling back to ${tag}..."
    detect_os

    local rollback_dir="${INSTALL_DIR}/${tag}"
    if [[ ! -d "${rollback_dir}" ]]; then
        die "Release directory ${rollback_dir} not found. Cannot rollback."
    fi

    ln -sfn "${rollback_dir}" "${CURRENT_LINK}"
    generate_local_settings
    django_setup
    deploy_frontend
    install_systemd_services
    start_services
    health_check
    info "Rolled back to ${tag}"
}

# ---------------------------------------------------------------------------
# Fresh install mode
# ---------------------------------------------------------------------------
do_fresh_install() {
    require_root
    info "Starting fresh installation of Sales Operations Platform (China domestic)..."
    info "This will install PostgreSQL, Valkey, Nginx, and configure the application."
    info "All mirrors are configured for China network."
    echo ""

    detect_os
    configure_mirrors
    create_service_users
    create_dirs

    info ""
    info "=== Installing System Dependencies ==="
    install_postgresql
    configure_postgresql
    install_valkey
    install_nginx
    configure_nginx
    install_python
    configure_pip_mirror

    info ""
    info "=== Pulling Release Artifacts ==="
    pull_release "latest"

    info ""
    info "=== Setting Up Application ==="
    setup_venv
    generate_local_settings
    django_setup
    deploy_frontend

    info ""
    info "=== Configuring Services ==="
    install_systemd_services
    install_logrotate
    memory_tuning
    register_backup_cron
    register_monitor_cron
    start_services

    info ""
    info "=== Health Check ==="
    health_check

    print_summary
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="${1:-}"

    case "${mode}" in
        --update)
            do_update
            ;;
        --rollback)
            do_rollback "${2:-}"
            ;;
        --help|-h)
            echo "Usage: sudo bash deploy-cn.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (none)        Fresh install (China mirrors)"
            echo "  --update      Update to latest release (Gitee/GitHub)"
            echo "  --rollback <tag>  Rollback to specific release"
            echo "  --help        Show this help"
            echo ""
            echo "China Mirrors:"
            echo "  APT/DNF:     Aliyun (mirrors.aliyun.com)"
            echo "  PyPI:        Aliyun (mirrors.aliyun.com/pypi/simple)"
            echo "  Nginx:       Aliyun (mirrors.aliyun.com/nginx)"
            echo "  Python src:  Huawei Cloud (mirrors.huaweicloud.com)"
            echo "  Valkey src:  Gitee mirror (gitee.com/mirrors/Valkey)"
            echo "  Releases:    Gitee (gitee.com/${GITEE_OWNER}/${GITEE_REPO})"
            echo ""
            echo "Environment Variables:"
            echo "  DB_NAME         Database name (default: salesops)"
            echo "  DB_USER         Database user (default: salesops)"
            echo "  DB_PASSWORD     Database password (auto-generated)"
            echo "  VALKEY_PASSWORD Valkey password (auto-generated)"
            echo "  DJANGO_SECRET_KEY Django secret key (auto-generated)"
            echo "  ALLOWED_HOSTS   Comma-separated hosts"
            echo "  GITEE_OWNER     Gitee org/user (default: wxbns)"
            echo "  GITEE_REPO      Gitee repository name (default: sales-operations-platform)"
            ;;
        *)
            do_fresh_install
            ;;
    esac
}

main "$@"
