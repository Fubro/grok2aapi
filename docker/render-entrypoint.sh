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
# 模式二：从环境变量（或自动生成）生成配置文件
# =============================================================================
elif [ -n "${GROK2API_JWT_SECRET:-}" ] || [ -n "${GROK2API_CREDENTIAL_ENCRYPTION_KEY:-}" ] || [ -z "${GROK2API_JWT_SECRET:-}" ]; then
  echo "[render-entrypoint] 从环境变量/自动生成 config.yaml ..."

  # ---- 密钥处理（凭据加密密钥必须稳定） ----
  # CREDENTIAL_ENCRYPTION_KEY 用于加密账号凭据：一旦变更，已存账号将无法解密。
  # 因此这里强制要求由环境变量提供，绝不静默随机生成，否则会损坏已有账号。
  CREDENTIAL_KEY="${GROK2API_CREDENTIAL_ENCRYPTION_KEY:-}"
  # JWT_SECRET 只影响登录状态安全性；未设置时允许临时生成，但会告警。
  JWT_SECRET="${GROK2API_JWT_SECRET:-}"
  ADMIN_PASS="${GROK2API_ADMIN_PASSWORD:-$(openssl rand -base64 16)}"
  ADMIN_USER="${GROK2API_ADMIN_USERNAME:-admin}"

  if [ -z "$CREDENTIAL_KEY" ]; then
    echo "[render-entrypoint] 错误: 必须设置 GROK2API_CREDENTIAL_ENCRYPTION_KEY（账号凭据加密密钥）。" >&2
    echo "[render-entrypoint] 请在 Render Dashboard → Environment 中设置一个固定密钥。" >&2
    echo "[render-entrypoint] 生成方式: openssl rand -base64 32" >&2
    echo "[render-entrypoint] 注意: 该密钥一旦用于保存账号后切勿更改，否则已有账号将无法解密。" >&2
    exit 1
  fi
  if [ -z "$JWT_SECRET" ]; then
    echo "[render-entrypoint] 警告: 未设置 GROK2API_JWT_SECRET，每次部署登录密钥会变化（仅影响登录，不影响账号数据）。" >&2
    echo "[render-entrypoint] 建议在 Render Dashboard → Environment 设置固定值以确保登录状态稳定。" >&2
    JWT_SECRET="$(openssl rand -hex 32)"
  fi

  echo "[render-entrypoint] CREDENTIAL_ENCRYPTION_KEY: 使用环境变量（稳定）"
  echo "[render-entrypoint] JWT_SECRET: $([ -n "${GROK2API_JWT_SECRET:-}" ] && echo '使用环境变量（稳定）' || echo '自动生成（不稳定）')"
  echo "[render-entrypoint] 管理员账号: ${ADMIN_USER}"
  echo "[render-entrypoint] 管理员密码: ${ADMIN_PASS}"

  # ---- 判断数据库类型 ----
  DB_URL="$(echo "${GROK2API_DATABASE_URL:-}" | tr -d '[:space:]')"
  if [ -n "$DB_URL" ]; then
    echo "[render-entrypoint] 数据库: PostgreSQL（外部）"
    DATABASE_DRIVER="postgres"
    DATABASE_BLOCK="  driver: postgres
  postgres:
    dsn: \"${DB_URL}\"
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
  listen: "0.0.0.0:${PORT:-8000}"
  maxBodyBytes: 33554432
  readTimeout: 15m
  requestTimeout: 2h
  swaggerEnabled: false

auth:
  accessTokenTTL: 15m
  refreshTokenTTL: 720h
  secureCookies: false

secrets:
  jwtSecret: "${JWT_SECRET}"
  credentialEncryptionKey: "${CREDENTIAL_KEY}"

bootstrapAdmin:
  username: "${ADMIN_USER}"
  password: "${ADMIN_PASS}"

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
  echo "[render-entrypoint] === 生成的配置 ==="
  grep -v -E '^(#|jwtSecret|credentialEncryptionKey|password|dsn)' "$CONFIG_TARGET" || true
  echo "[render-entrypoint] === 配置结束 ==="

# =============================================================================
# 错误：无配置文件也无环境变量（理论上不会触发，因为会自动生成）
# =============================================================================
else
  echo "[render-entrypoint] 错误: 未找到配置文件，也无法生成密钥（缺少 openssl）" >&2
  exit 1
fi

# ---- 设置文件权限 ----
chown grok2api:grok2api "$CONFIG_TARGET"
chmod 0600 "$CONFIG_TARGET"

# ---- 以 grok2api 用户身份启动应用，捕获错误 ----
echo "[render-entrypoint] 正在启动 grok2api..."
su-exec grok2api:grok2api "$@" 2>&1 || echo "[render-entrypoint] 应用退出码: $?"