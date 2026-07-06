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
