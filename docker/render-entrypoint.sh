#!/bin/sh
# =============================================================================
# Render.com 专用入口脚本 — 从环境变量动态生成 config.yaml
# =============================================================================
# 将此脚本放入项目的 docker/ 目录，并修改 Dockerfile 中的入口点：
#
#   修改前：
#     COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/grok2api-entrypoint
#
#   修改后（Render 部署用）：
#     COPY --chmod=0755 docker/render-entrypoint.sh /usr/local/bin/grok2api-entrypoint
# =============================================================================
# 本脚本兼容三种模式：
#   1. 传统模式：GROK2API_CONFIG_SOURCE 指向的文件存在 → 直接使用该文件
#   2. PostgreSQL 模式：设置了 GROK2API_DATABASE_URL → 使用 PostgreSQL 数据库
#   3. SQLite 模式：仅设置了密钥 → 使用 SQLite（数据不持久，仅供测试）
# =============================================================================

set -eu

umask 077

# ---- 配置路径 ----
CONFIG_SOURCE="${GROK2API_CONFIG_SOURCE:-/run/grok2api/config.yaml}"
CONFIG_TARGET="/app/config.yaml"

# =============================================================================
# 模式一：已挂载配置文件
# =============================================================================
if [ -f "$CONFIG_SOURCE" ]; then
  echo "[render-entrypoint] 使用已挂载的配置文件: $CONFIG_SOURCE"
  cp "$CONFIG_SOURCE" "$CONFIG_TARGET"

# =============================================================================
# 模式二：从环境变量生成配置文件
# =============================================================================
elif [ -n "${GROK2API_JWT_SECRET:-}" ] && [ -n "${GROK2API_CREDENTIAL_ENCRYPTION_KEY:-}" ]; then
  echo "[render-entrypoint] 从环境变量生成 config.yaml ..."

  # 检查必需变量
  if [ -z "${GROK2API_ADMIN_PASSWORD:-}" ]; then
    echo "[render-entrypoint] 错误: GROK2API_ADMIN_PASSWORD 未设置" >&2
    exit 1
  fi

  # ---- 判断数据库类型 ----
  if [ -n "${GROK2API_DATABASE_URL:-}" ]; then
    echo "[render-entrypoint] 数据库: PostgreSQL（外部）"
    DATABASE_DRIVER="postgres"
    DATABASE_BLOCK="  driver: postgres
  postgres:
    dsn: \"${GROK2API_DATABASE_URL}\"
    maxOpenConns: 20
    maxIdleConns: 5"
  else
    echo "[render-entrypoint] 数据库: SQLite（本地，数据不持久）"
    DATABASE_DRIVER="sqlite"
    DATABASE_BLOCK="  driver: sqlite
  sqlite:
    path: \"./data/backend.db\""
  fi

  cat > "$CONFIG_TARGET" << RENDEREOF
# =============================================================================
# 由 Render 入口脚本自动生成 — 请勿手动编辑
# 如需修改配置，请在 Render Dashboard 中更新环境变量后重新部署
# =============================================================================

server:
  listen: "0.0.0.0:8000"
  maxBodyBytes: 33554432
  readTimeout: 15m
  requestTimeout: 2h
  swaggerEnabled: false

auth:
  accessTokenTTL: 15m
  refreshTokenTTL: 720h
  secureCookies: false

secrets:
  jwtSecret: "${GROK2API_JWT_SECRET}"
  credentialEncryptionKey: "${GROK2API_CREDENTIAL_ENCRYPTION_KEY}"

bootstrapAdmin:
  username: "${GROK2API_ADMIN_USERNAME:-admin}"
  password: "${GROK2API_ADMIN_PASSWORD}"

frontend:
  staticPath: "./frontend/dist"

database:
${DATABASE_BLOCK}

runtimeStore:
  driver: memory

media:
  driver: local
  local:
    path: "./data/media"

deployment:
  replicas: 1
  instanceID: "render-1"
  clusterID: "grok2api-render"
  sharedMedia: false

routing:
  reasoningReplayEnabled: true
  reasoningReplayTTL: 1h
  reasoningReplayMaxEntries: 10240
  segmentedSelectorEnabled: false
  segmentedSelectorMinCandidates: 3000
  segmentedSelectorWindowSize: 64

audit:
  bufferSize: 16384
  batchSize: 256
  flushInterval: 250ms
  commitDelay: 5ms
  ledgerMode: enforce
  ledgerFailureThreshold: 1
  ledgerUnhealthyGrace: 10s
  ledgerQueueHighWatermarkPercent: 90
RENDEREOF

  echo "[render-entrypoint] config.yaml 已生成至 $CONFIG_TARGET"
  echo "[render-entrypoint] 管理员账号: ${GROK2API_ADMIN_USERNAME:-admin}"
  echo "[render-entrypoint] 管理员密码: (已设置，请登录后修改)"

# =============================================================================
# 错误：无配置文件也无环境变量
# =============================================================================
else
  echo "[render-entrypoint] 错误: 未找到配置文件，也未设置环境变量" >&2
  echo "" >&2
  echo "  请选择以下方式之一：" >&2
  echo "    1. 挂载配置文件到 $CONFIG_SOURCE" >&2
  echo "    2. 设置环境变量 GROK2API_JWT_SECRET 和 GROK2API_CREDENTIAL_ENCRYPTION_KEY" >&2
  echo "    3. 设置 GROK2API_DATABASE_URL 连接外部 PostgreSQL" >&2
  echo "" >&2
  echo "  快速生成密钥：" >&2
  echo "    openssl rand -hex 32       # → JWT_SECRET" >&2
  echo "    openssl rand -base64 32    # → CREDENTIAL_ENCRYPTION_KEY" >&2
  exit 1
fi

# ---- 设置文件权限 ----
chown grok2api:grok2api "$CONFIG_TARGET"
chmod 0600 "$CONFIG_TARGET"

# ---- 以 grok2api 用户身份启动应用 ----
exec su-exec grok2api:grok2api "$@"