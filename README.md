# Sales Operations Platform — Distribution

本仓库为销售运营平台的**生产部署发行库**，由 CI 自动从代码库推送全量构建产物与部署配置。

> **请勿手动修改本仓库文件**，所有内容由 CI 全量覆盖。如需修改，请在[代码库](https://github.com/Mcloud136/sales-operations-platform-source)提交后等待 CI 自动同步。

## 目录结构

```
├── backend/
│   └── sales-operations-platform   # Rust release 二进制（strip）
├── frontend/                       # Vue 前端生产产物（Vite build）
│   ├── index.html
│   └── assets/
├── migrations/                     # PostgreSQL 迁移脚本（sqlx 自动执行）
├── config/
│   ├── sales-ops.service           # systemd 服务单元
│   ├── sales-ops.conf              # Nginx 反向代理配置
│   ├── .env.production             # 环境变量模板
│   └── .env.example                # 变量说明参考
├── scripts/
│   ├── setup.sh                    # 一键首次部署（安装所有依赖）
│   ├── deploy.sh                   # 日常更新部署脚本
│   ├── backup.sh                   # 数据库+配置+文件备份
│   └── generate-ssl.sh             # 自签 SSL 证书生成
├── rbac_model.conf                 # Casbin RBAC 模型定义
├── VERSION.json                    # 当前版本元信息
└── README.md
```

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Ubuntu 26.04 LTS |
| CPU | 1+ 核心 |
| 内存 | 2GB+ |
| 磁盘 | 20GB+ |
| 网络 | 可访问 Gitee/GitHub |

## 首次部署（一键安装）

适用于全新 Ubuntu 26.04 服务器，自动安装所有依赖并启动服务：

```bash
# 克隆发行库
git clone https://gitee.com/wxbns/sales-operations-platform.git /tmp/sales-ops-dist

# 执行一键部署脚本（需 root 权限）
sudo bash /tmp/sales-ops-dist/scripts/setup.sh
```

脚本会自动完成：
1. 系统更新 + 基础工具安装
2. PostgreSQL 18 安装 + 数据库创建
3. Valkey 9.1 安装 + systemd 服务配置
4. SeaweedFS 安装（Master/Volume/Filer/S3 Gateway）
5. 自签 SSL 证书生成（10年有效期）
6. 克隆发行库到 `/opt/sales-ops`
7. 配置环境变量（JWT 密钥自动生成）
8. 创建 `sales-ops` 服务用户 + systemd 服务
9. 配置 Nginx 反向代理（HTTPS 8089 + HTTP 8088 重定向）
10. 启动所有服务 + 健康检查
11. 配置每日自动备份 cron（凌晨 2:00）

### 默认管理员账号

| 项目 | 值 |
|------|-----|
| 用户名 | `admin` |
| 密码 | `admin@123` |
| 租户 ID | `11111111-1111-1111-1111-111111111111` |
| 首次登录 | 强制修改密码 |

### 自定义配置

部署前可通过环境变量覆盖默认值：

```bash
DB_PASSWORD="your_password" \
HTTPS_PORT=8089 \
HTTP_PORT=8088 \
sudo bash /tmp/sales-ops-dist/scripts/setup.sh
```

## 后续更新

使用更新脚本拉取最新版本并重启服务：

```bash
sudo /opt/sales-ops/scripts/deploy.sh
```

更新流程：
1. 备份当前版本（二进制 + 前端 + 配置）
2. `git pull` 拉取最新产物
3. 修复 CRLF 换行符
4. 设置文件权限
5. 重启后端 + 重载 Nginx
6. 30 秒健康检查

> **注意**：数据库迁移由后端启动时通过 `sqlx::migrate!()` 自动执行，无需手动操作。

## 手动部署步骤

如需逐步手动部署，参考以下步骤：

```bash
# 1. 克隆发行库
git clone https://gitee.com/wxbns/sales-operations-platform.git /opt/sales-ops

# 2. 配置环境变量
cp /opt/sales-ops/config/.env.production /opt/sales-ops/config/.env
vim /opt/sales-ops/config/.env
# 替换 CHANGE_ME_* 占位符

# 3. 创建服务用户
sudo useradd -r -m -s /bin/bash sales-ops
sudo chown -R sales-ops:sales-ops /opt/sales-ops

# 4. 安装 systemd 服务
sudo cp /opt/sales-ops/config/sales-ops.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sales-ops

# 5. 安装 Nginx 配置（Ubuntu 26.04 使用 conf.d/）
sudo cp /opt/sales-ops/config/sales-ops.conf /etc/nginx/conf.d/
sudo nginx -t && sudo systemctl reload nginx
```

## 备份与恢复

### 自动备份

cron 每日凌晨 2:00 执行，保留 7 天：

```bash
# 查看备份
ls -lh /opt/sales-ops-backups/

# 手动执行备份
sudo /opt/sales-ops/scripts/backup.sh
```

### 恢复数据库

```bash
# 恢复 PostgreSQL 数据库
sudo -u postgres pg_restore -d sales_ops --clean /opt/sales-ops-backups/db-XXXXXXXX-XXXXXX.dump
```

## 回滚

```bash
# 查看历史版本
cd /opt/sales-ops && git log --oneline

# 回滚到指定版本
git checkout <commit-sha>
sudo systemctl restart sales-ops
```

## 服务管理

```bash
# 查看所有服务状态
systemctl status sales-ops postgresql valkey-server nginx seaweedfs-master seaweedfs-volume seaweedfs-filer seaweedfs-s3

# 查看后端日志
journalctl -u sales-ops -f

# 重启后端
sudo systemctl restart sales-ops

# 重启所有服务
sudo systemctl restart sales-ops postgresql valkey-server nginx seaweedfs-master seaweedfs-volume seaweedfs-filer seaweedfs-s3
```

## 端口说明

| 服务 | 端口 | 说明 |
|------|------|------|
| Nginx HTTPS | 8089 | 前端 + API 反向代理 |
| Nginx HTTP | 8088 | 301 重定向到 HTTPS |
| Backend | 3000 | Rust 后端（仅 localhost） |
| PostgreSQL | 5432 | 数据库（仅 localhost） |
| Valkey | 6379 | 缓存（仅 localhost） |
| SeaweedFS Master | 9333 | 对象存储主控（仅 localhost） |
| SeaweedFS Filer | 8888 | 文件管理（仅 localhost） |
| SeaweedFS S3 | 8333 | S3 兼容接口（仅 localhost） |

## 相关链接

- **代码库**：https://github.com/Mcloud136/sales-operations-platform-source
- **Wiki**：https://github.com/Mcloud136/sales-operations-platform/wiki
- **Gitee 镜像**：https://gitee.com/wxbns/sales-operations-platform
# Sales Operations Platform — Distribution

本仓库为销售运营平台的**生产部署发行库**，由 CI 自动从代码库推送全量构建产物与部署配置。

> **请勿手动修改本仓库文件**，所有内容由 CI 全量覆盖。如需修改，请在[代码库](https://github.com/Mcloud136/sales-operations-platform-source)提交后等待 CI 自动同步。

## 目录结构

```
├── backend/
│   └── sales-operations-platform   # Rust release 二进制（strip）
├── frontend/                       # Vue 前端生产产物（Vite build）
│   ├── index.html
│   └── assets/
├── migrations/                     # PostgreSQL 迁移脚本（sqlx 格式）
├── config/
│   ├── sales-ops.service           # systemd 服务单元
│   ├── sales-ops.conf              # Nginx 反向代理配置
│   └── .env.example                # 环境变量模板
├── scripts/
│   ├── deploy.sh                   # 一键部署脚本
│   └── backup.sh                   # 数据库+配置备份脚本
└── VERSION.json                    # 当前版本元信息
```

## VERSION.json 字段说明

| 字段         | 说明                          |
| ------------ | ----------------------------- |
| `commit`     | 代码库 commit SHA             |
| `branch`     | 构建分支（固定为 `main`）     |
| `build_time` | UTC 构建时间（ISO 8601）      |
| `run_id`     | GitHub Actions 运行 ID        |

## 部署步骤

```bash
# 1. 克隆发行库到目标机器
git clone https://gitee.com/wxbns/sales-operations-platform.git /opt/sales-ops

# 2. 复制并修改环境变量
cp /opt/sales-ops/config/.env.example /opt/sales-ops/config/.env
vim /opt/sales-ops/config/.env

# 3. 安装 systemd 服务
sudo cp /opt/sales-ops/config/sales-ops.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sales-ops

# 4. 安装 Nginx 配置
sudo cp /opt/sales-ops/config/sales-ops.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/sales-ops.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 5. 执行数据库迁移
source /opt/sales-ops/config/.env
for f in /opt/sales-ops/migrations/*.up.sql; do
  psql "$DATABASE_URL" -f "$f"
done
```

## 后续更新

```bash
cd /opt/sales-ops
git pull origin main
sudo systemctl restart sales-ops
```

或使用一键部署脚本：

```bash
sudo /opt/sales-ops/scripts/deploy.sh
```

## 回滚

```bash
# 查看历史版本
git log --oneline

# 回滚到指定版本
git checkout <commit-sha>
sudo systemctl restart sales-ops
```

## 相关链接

- **代码库**：https://github.com/Mcloud136/sales-operations-platform-source
- **Wiki**：https://github.com/Mcloud136/sales-operations-platform/wiki
