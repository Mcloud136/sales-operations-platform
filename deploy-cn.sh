#!/usr/bin/env bash
#
# deploy-cn.sh - 国内部署版 (Gitee + 国内镜像源)
# 基于 deploy.sh 修改，所有外部资源使用国内镜像
# Supports: Ubuntu 22.04+ (APT), CentOS 8+ / RHEL 8+ (DNF)
# Usage:
#   bash deploy-cn.sh                    # Fresh install
#   bash deploy-cn.sh --update            # Update from latest Gitee Release
#   bash deploy-cn.sh --rollback <tag>   # Rollback to a specific release
#
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

# Django
DJANGO_SECRET_KEY="${DJANGO_SECRET_KEY:-$(openssl rand -hex 50)}"
ALLOWED_HOSTS="${ALLOWED_HOSTS:-$(hostname -f),$(hostname),localhost,127.0.0.1}"
SECURE_SSL_REDIRECT="False"
SESSION_COOKIE_SECURE="False"
CSRF_COOKIE_SECURE="False"

# Gitee (国内仓库)
GITEE_REPO="${GITEE_REPO:-sales-operations-platform}"
GITEE_OWNER="${GITEE_OWNER:-wxbns}"

# PostgreSQL pinned major version (auto-installs latest patch)
PG_MAJOR="18"

# Valkey pinned version
VALKEY_VERSION="9.1.0"

# 国内镜像源
# PostgreSQL: try multiple sources for GPG key and APT repo
MIRROR_PG_APT="https://apt.postgresql.org/pub/repos/apt"
MIRROR_PG_KEY="https://www.postgresql.org/media/keys/ACCC4CF8.asc"
MIRROR_PG_KEY_FALLBACK="https://mirrors.tuna.tsinghua.edu.cn/postgresql/repos/apt/ACCC4CF8.asc"
MIRROR_APT="https://mirrors.aliyun.com"
MIRROR_NGINX="https://mirrors.aliyun.com/nginx"
MIRROR_PYTHON_SRC="https://mirrors.huaweicloud.com/python"
MIRROR_PIP="https://mirrors.aliyun.com/pypi/simple"

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
# Step 1.5: Configure system package mirrors (国内镜像)
# ---------------------------------------------------------------------------
configure_mirrors() {
    info "Configuring domestic mirrors for system packages..."

    case "${PKG_MANAGER}" in
        apt)
            local codename
            codename=$(lsb_release -cs)

            # Ubuntu 24.04+ uses DEB822 format: /etc/apt/sources.list.d/ubuntu.sources
            # Older Ubuntu uses legacy format: /etc/apt/sources.list
            if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
                # DEB822 format (Ubuntu 24.04+)
                local sources_file="/etc/apt/sources.list.d/ubuntu.sources"
                local backup="${sources_file}.bak"
                if [[ ! -f "${backup}" ]]; then
                    cp "${sources_file}" "${backup}"
                fi

                # Replace URIs lines with Aliyun mirror
                sed -i "s|^URIs:.*|URIs: ${MIRROR_APT}/ubuntu|g" "${sources_file}"

                # Disable legacy sources.list to avoid "configured multiple times" warnings
                if [[ -f /etc/apt/sources.list && ! -f /etc/apt/sources.list.disabled ]]; then
                    cp /etc/apt/sources.list /etc/apt/sources.list.disabled
                    : > /etc/apt/sources.list
                fi

                info "APT sources configured (Aliyun mirror, DEB822 format)"
            elif [[ -f /etc/apt/sources.list ]]; then
                # Legacy format (Ubuntu 22.04 and older)
                if [[ ! -f /etc/apt/sources.list.bak ]]; then
                    cp /etc/apt/sources.list /etc/apt/sources.list.bak
                fi
                cat > /etc/apt/sources.list <<APT_EOF
deb ${MIRROR_APT}/ubuntu ${codename} main restricted universe multiverse
deb ${MIRROR_APT}/ubuntu ${codename}-updates main restricted universe multiverse
deb ${MIRROR_APT}/ubuntu ${codename}-security main restricted universe multiverse
deb ${MIRROR_APT}/ubuntu ${codename}-backports main restricted universe multiverse
APT_EOF
                info "APT sources configured (Aliyun mirror, legacy format)"
            else
                warn "No APT sources file found, skipping mirror configuration"
            fi
            ;;
        dnf)
            # Configure Aliyun YUM mirror
            if [[ ! -f /etc/yum.repos.d/CentOS-Base.repo.bak ]]; then
                cp /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak 2>/dev/null || true
            fi

            # Use Aliyun vault mirror for CentOS Stream / RHEL
            sed -i 's|mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/*.repo 2>/dev/null || true
            sed -i 's|#baseurl=https://mirror.stream.centos.org|baseurl=https://mirrors.aliyun.com/centos-stream|g' /etc/yum.repos.d/*.repo 2>/dev/null || true
            info "DNF repos configured (Aliyun mirror)"
            ;;
    esac

    info "Domestic mirrors configured"
}

# ---------------------------------------------------------------------------
# Step 2: Install PostgreSQL 18 from official repository
# ---------------------------------------------------------------------------
install_postgresql() {
    info "Installing PostgreSQL ${PG_MAJOR} (official APT repo)..."

    if command -v psql &>/dev/null && psql --version | grep -q "psql (PostgreSQL) ${PG_MAJOR}"; then
        info "PostgreSQL ${PG_MAJOR} already installed"
        return
    fi

    case "${PKG_MANAGER}" in
        apt)
            # Add PostgreSQL official APT repository
            pkg_install_no_update curl ca-certificates gnupg lsb-release

            # Download GPG key with fallback
            if ! curl -fsSL "${MIRROR_PG_KEY}" \
                | gpg --batch --dearmor --yes -o /usr/share/keyrings/postgresql-keyring.gpg 2>/dev/null; then
                warn "Primary GPG key URL failed, trying fallback..."
                curl -fsSL "${MIRROR_PG_KEY_FALLBACK}" \
                    | gpg --batch --dearmor --yes -o /usr/share/keyrings/postgresql-keyring.gpg \
                    || die "Failed to download PostgreSQL GPG key from all sources"
            fi

            echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] \
${MIRROR_PG_APT} $(lsb_release -cs)-pgdg main" \
                > /etc/apt/sources.list.d/pgdg.list
            apt-get update -qq

            # Verify pgdg source is available
            if ! apt-cache show "postgresql-${PG_MAJOR}" &>/dev/null; then
                die "PostgreSQL ${PG_MAJOR} not found in APT. pgdg repo may be unreachable. Check: cat /etc/apt/sources.list.d/pgdg.list"
            fi

            # Install PG major version
            apt-get install -y "postgresql-${PG_MAJOR}" \
                "postgresql-client-${PG_MAJOR}"
            # Prevent auto-upgrades to next major version
            echo "postgresql-${PG_MAJOR} hold" | dpkg --set-selections
            ;;
        dnf)
            # Install PostgreSQL yum repository (direct, no good Chinese mirror for PG RPM)
            pkg_install_no_update curl
            dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm --eval '%rhel')-x86_64/pgdg-redhat-repo-latest.noarch.rpm
            dnf -qy module disable postgresql
            dnf install -y "postgresql${PG_MAJOR}-server" \
                "postgresql${PG_MAJOR}-contrib" \
                "postgresql${PG_MAJOR}-devel"
            ;;
    esac

    # Ensure service is enabled and started
    systemctl enable postgresql
    systemctl start postgresql

    # Record installed version
    local installed_pg_version
    installed_pg_version=$(psql --version | grep -oP '\d+\.\d+' | head -1)
    echo "postgresql=${installed_pg_version}" >> "${VERSION_MANIFEST}"
    info "PostgreSQL ${installed_pg_version} installed"
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
# Step 4: Install Valkey 9.1 from source (GitHub release)
# ---------------------------------------------------------------------------
install_valkey() {
    info "Installing Valkey ${VALKEY_VERSION} (source build)..."

    if valkey-server --version 2>/dev/null | grep -q "valkey-server.*v=${VALKEY_VERSION}"; then
        info "Valkey ${VALKEY_VERSION} already installed"
        return
    fi

    # Install build dependencies
    case "${PKG_MANAGER}" in
        apt)
            pkg_install_no_update build-essential pkg-config
            ;;
        dnf)
            pkg_install_no_update gcc make pkg-config
            ;;
    esac

    # Download and build from source
    local src_dir="/tmp/valkey-${VALKEY_VERSION}"
    local tarball="/tmp/valkey-${VALKEY_VERSION}.tar.gz"

    if [[ ! -f "${tarball}" ]]; then
        curl -fsSL "https://github.com/valkey-io/valkey/archive/refs/tags/${VALKEY_VERSION}.tar.gz" \
            -o "${tarball}" || die "Failed to download Valkey ${VALKEY_VERSION} source"
    fi

    rm -rf "${src_dir}"
    tar -xzf "${tarball}" -C /tmp
    # GitHub archive extracts to valkey-VERSION/
    if [[ ! -d "${src_dir}" ]]; then
        # Try alternate extraction path
        src_dir=$(find /tmp -maxdepth 1 -name "valkey-*${VALKEY_VERSION}*" -type d | head -1)
    fi

    cd "${src_dir}"
    make -j"$(nproc)" BUILD_TLS=no 2>&1 | tail -5
    make install PREFIX=/usr/local

    # Create valkey user
    if ! id valkey &>/dev/null; then
        useradd -r -m -d /var/lib/valkey -s /usr/sbin/nologin -c "Valkey Server" valkey
    fi

    # Create directories
    mkdir -p /etc/valkey /var/lib/valkey /var/log/valkey "${VALKEY_SOCK_DIR}"
    chown -R valkey:valkey /var/lib/valkey /var/log/valkey

    # Symlink binaries
    ln -sf /usr/local/bin/valkey-server /usr/local/bin/valkey-server
    ln -sf /usr/local/bin/valkey-cli /usr/local/bin/valkey-cli

    # Create systemd service
    cat > /etc/systemd/system/valkey-server.service <<'VKEY_SERVICE'
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
VKEY_SERVICE

    cd /
    rm -rf "${src_dir}" "${tarball}"

    # Configure Valkey
    local valkey_conf="/etc/valkey/valkey.conf"
    mkdir -p /etc/valkey

    cat > "${valkey_conf}" <<'VAKEY_EOF'
# Valkey configuration - Sales Operations Platform
# Generated by deploy-cn.sh

bind 0.0.0.0 -
protected-mode yes
port 0
unixsocket /var/run/valkey/valkey.sock
unixsocketperm 770

# Per-database ACLs
aclfile /etc/valkey/users.acl

# Memory (will be tuned by deploy-cn.sh based on total RAM)

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
    mkdir -p /var/lib/valkey /var/log/valkey
    chown -R valkey:valkey /var/lib/valkey /var/log/valkey
    chmod 770 "${VALKEY_SOCK_DIR}"

    # Ensure valkey user can write to socket dir
    usermod -aG app_user valkey

    systemctl enable valkey-server
    systemctl start valkey-server

    echo "valkey=${VALKEY_VERSION}" >> "${VERSION_MANIFEST}"
    info "Valkey ${VALKEY_VERSION} installed with per-db ACLs"
}

# ---------------------------------------------------------------------------
# Step 5: Install Nginx from Aliyun mirror
# ---------------------------------------------------------------------------
install_nginx() {
    info "Installing Nginx (Aliyun mirror)..."

    if command -v nginx &>/dev/null && nginx -v 2>&1 | grep -q "nginx version"; then
        info "Nginx already installed"
        return
    fi

    case "${PKG_MANAGER}" in
        apt)
            pkg_install_no_update curl ca-certificates gnupg lsb-release
            curl -fsSL https://nginx.org/keys/nginx_signing.key \
                | gpg --batch --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
${MIRROR_NGINX}/ubuntu $(lsb_release -cs) nginx" \
                > /etc/apt/sources.list.d/nginx.list
            echo "Package: *\nPin: origin mirrors.aliyun.com\nPin-Priority: 900\n" \
                > /etc/apt/preferences.d/99nginx
            apt-get update -qq
            apt-get install -y nginx
            ;;
        dnf)
            cat > /etc/yum.repos.d/nginx.repo <<'NGINX_REPO'
[nginx-stable]
name=nginx stable repo
baseurl=https://mirrors.aliyun.com/nginx/centos/$releasever/$basearch/
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
# Step 6: Install Python 3.13 (Huawei Cloud mirror)
# ---------------------------------------------------------------------------
install_python() {
    info "Installing Python 3.13 (domestic mirror)..."

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
            curl -fsSL "${MIRROR_PYTHON_SRC}/3.13.0/Python-3.13.0.tgz" \
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
# Step 6.5: Configure pip to use domestic mirror
# ---------------------------------------------------------------------------
configure_pip_mirror() {
    info "Configuring pip mirror (Aliyun)..."

    local pip_conf_dir="/etc/pip"
    mkdir -p "${pip_conf_dir}"

    cat > "${pip_conf_dir}/pip.conf" <<PIP_EOF
[global]
index-url = ${MIRROR_PIP}/
trusted-host = mirrors.aliyun.com
PIP_EOF

    # Also configure for app_user
    local app_pip_dir="/opt/sales-ops/.config/pip"
    mkdir -p "${app_pip_dir}"
    cp "${pip_conf_dir}/pip.conf" "${app_pip_dir}/pip.conf"
    chown -R app_user:app_user "/opt/sales-ops/.config"

    info "pip mirror configured (Aliyun: ${MIRROR_PIP})"
}

# ---------------------------------------------------------------------------
# Step 7: Pull release artifacts from Gitee
# ---------------------------------------------------------------------------
pull_release() {
    local tag="${1:-latest}"

    info "Pulling release artifacts from Gitee (tag: ${tag})..."

    mkdir -p "${INSTALL_DIR}"

    local release_info
    if [[ "${tag}" == "latest" ]]; then
        release_info=$(curl -sL "https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/latest")
    else
        release_info=$(curl -sL "https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/tags/${tag}")
    fi

    local release_tag
    release_tag=$(echo "${release_info}" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    local release_dir="${INSTALL_DIR}/${release_tag}"
    mkdir -p "${release_dir}"

    # Download assets
    for asset_name in frontend-dist.zip backend-dist.tar.gz checksums.sha256; do
        local download_url
        download_url=$(echo "${release_info}" | python3 -c "
import sys, json
assets = json.load(sys.stdin).get('assets', [])
for a in assets:
    if a['name'] == '${asset_name}':
        print(a.get('browser_download_url', a.get('download_url', '')))
        break
")

        if [[ -z "${download_url}" ]]; then
            warn "Asset '${asset_name}' not found in release"
            continue
        fi

        local dest="${release_dir}/${asset_name}"
        if [[ -f "${dest}" ]]; then
            info "Asset '${asset_name}' already downloaded"
        else
            curl -fsSL "${download_url}" -o "${dest}"
            info "Downloaded '${asset_name}'"
        fi
    done

    # Verify checksums
    if [[ -f "${release_dir}/checksums.sha256" ]]; then
        (cd "${release_dir}" && sha256sum -c checksums.sha256) || die "Checksum verification failed!"
        info "Checksums verified"
    fi

    # Extract
    mkdir -p "${release_dir}/frontend"
    mkdir -p "${release_dir}/backend"
    unzip -o "${release_dir}/frontend-dist.zip" -d "${release_dir}/frontend"
    tar -xzf "${release_dir}/backend-dist.tar.gz" -C "${release_dir}/backend"

    # Symlink current
    ln -sfn "${release_dir}" "${CURRENT_LINK}"

    echo "release=${release_tag}" >> "${VERSION_MANIFEST}"
    info "Release ${release_tag} deployed to ${release_dir}"
}

# ---------------------------------------------------------------------------
# Step 8: Create virtual environment and install dependencies (pip mirror)
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

    # Install dependencies with pip mirror
    if [[ -f "${CURRENT_LINK}/backend/requirements.txt" ]]; then
        "${venv_dir}/bin/pip" install --upgrade pip setuptools wheel \
            -i "${MIRROR_PIP}/" --trusted-host mirrors.aliyun.com
        "${venv_dir}/bin/pip" install --require-hashes \
            -r "${CURRENT_LINK}/backend/requirements.txt" \
            -i "${MIRROR_PIP}/" --trusted-host mirrors.aliyun.com
        info "Python dependencies installed (--require-hashes, mirror: Aliyun)"
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

    local venv_bin="${APP_DIR}/venv/bin"
    local backend_dir="${CURRENT_LINK}/backend"

    local workers
    workers=$(python3 -c "import os; print(max(2, min(8, os.cpu_count() or 4)))")

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
        pg_shared_buffers_mb=16384
    fi

    # Valkey maxmemory = 20% of RAM
    local valkey_maxmemory_mb=$((total_ram_gb * 204))
    if [[ ${valkey_maxmemory_mb} -gt 8192 ]]; then
        valkey_maxmemory_mb=8192
    fi

    local valkey_maxmemory_bytes=$((valkey_maxmemory_mb * 1024 * 1024))

    # Update Valkey config with memory limit
    local valkey_conf="/etc/valkey/valkey.conf"
    if [[ -f "${valkey_conf}" ]]; then
        sed -i "s/^# maxmemory.*/maxmemory ${valkey_maxmemory_bytes}/" "${valkey_conf}"
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

    crontab -l 2>/dev/null | grep -v "backup.sh" | { cat; echo "${cron_entry}"; } | crontab -
    info "Backup cron registered"
}

# ---------------------------------------------------------------------------
# Step 16: Register monitor cron
# ---------------------------------------------------------------------------
register_monitor_cron() {
    info "Registering monitor cron job (every 5 minutes)..."

    local cron_entry="*/5 * * * * root ${CURRENT_LINK}/scripts/monitor.sh >> ${LOG_DIR}/monitor.log 2>&1"

    crontab -l 2>/dev/null | grep -v "monitor.sh" | { cat; echo "${cron_entry}"; } | crontab -
    info "Monitor cron registered"
}

# ---------------------------------------------------------------------------
# Step 17: Start all services
# ---------------------------------------------------------------------------
start_services() {
    info "Starting all services..."

    systemctl daemon-reload

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

    info "All services started"
}

# ---------------------------------------------------------------------------
# Step 18: Health check
# ---------------------------------------------------------------------------
health_check() {
    info "Running health check..."

    local errors=0

    if sudo -u postgres psql -d "${DB_NAME}" -c "SELECT 1" &>/dev/null; then
        info "  [OK] PostgreSQL"
    else
        error "  [FAIL] PostgreSQL"
        errors=$((errors + 1))
    fi

    if valkey-cli -s "${VALKEY_SOCK_DIR}/valkey.sock" -a "${VALKEY_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
        info "  [OK] Valkey"
    else
        error "  [FAIL] Valkey"
        errors=$((errors + 1))
    fi

    sleep 3
    if [[ -S "${SOCKET_DIR}/app.sock" ]]; then
        info "  [OK] Uvicorn socket"
    else
        error "  [FAIL] Uvicorn socket not found at ${SOCKET_DIR}/app.sock"
        errors=$((errors + 1))
    fi

    if nginx -t 2>/dev/null; then
        info "  [OK] Nginx config"
    else
        error "  [FAIL] Nginx config"
        errors=$((errors + 1))
    fi

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
    echo "  (Gitee + 国内镜像)"
    echo "=============================================="
    echo "  Access: http://$(hostname -f)"
    echo "  DB:     ${DB_NAME}@${DB_HOST}"
    echo "  Gitee:  https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}"
    echo "  Release: $(cat "${VERSION_MANIFEST}" | grep '^release=' | cut -d= -f2)"
    echo "=============================================="
}

# ---------------------------------------------------------------------------
# Step 19: Print deployment summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "Deployment Summary (国内部署):"
    echo "  OS:           ${OS_NAME}"
    echo "  App Dir:      ${APP_DIR}"
    echo "  Release:      $(readlink "${CURRENT_LINK}")"
    echo "  Gitee Repo:   https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}"
    echo "  PostgreSQL:   $(psql --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo 'N/A')"
    echo "  Valkey:       ${VALKEY_VERSION}"
    echo "  Nginx:        Aliyun mirror"
    echo "  Python:       $(python3.13 --version 2>&1)"
    echo "  pip Mirror:   ${MIRROR_PIP}"
    echo "  Socket Dir:   ${SOCKET_DIR}"
    echo "  Valkey Socket: ${VALKEY_SOCK_DIR}/valkey.sock"
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
# Update mode
# ---------------------------------------------------------------------------
do_update() {
    require_root
    info "Starting update mode (Gitee)..."
    detect_os
    pull_release "latest"
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
    info "Starting fresh installation of Sales Operations Platform (国内部署)..."
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
    install_python
    configure_pip_mirror

    info ""
    info "=== Pulling Release Artifacts (Gitee) ==="
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
            echo "Usage: bash deploy-cn.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (none)        Fresh install"
            echo "  --update      Update to latest release from Gitee"
            echo "  --rollback <tag>  Rollback to specific release"
            echo "  --help        Show this help"
            echo ""
            echo "Environment Variables:"
            echo "  DB_NAME         Database name (default: salesops)"
            echo "  DB_USER         Database user (default: salesops)"
            echo "  DB_PASSWORD     Database password (auto-generated)"
            echo "  VALKEY_PASSWORD Valkey password (auto-generated)"
            echo "  DJANGO_SECRET_KEY Django secret key (auto-generated)"
            echo "  ALLOWED_HOSTS   Comma-separated hosts"
            echo "  GITEE_OWNER     Gitee user/org (default: wxbns)"
            echo "  GITEE_REPO      Gitee repository name (default: sales-operations-platform)"
            echo ""
            echo "Domestic Mirrors Used:"
            echo "  PostgreSQL APT: ${MIRROR_PG_APT}"
            echo "  Nginx:          ${MIRROR_NGINX}"
            echo "  Python Source:  ${MIRROR_PYTHON_SRC}"
            echo "  pip:            ${MIRROR_PIP}"
            ;;
        *)
            do_fresh_install
            ;;
    esac
}

main "$@"
