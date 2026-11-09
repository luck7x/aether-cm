#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly STATE_FILE="${AETHER_BLUE_GREEN_STATE:-/root/aether-blue-green-last-success.env}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { log "错误：$*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || fail '必须使用 root 执行'
[[ -s "${STATE_FILE}" ]] || fail "状态文件不存在：${STATE_FILE}"
[[ "${1:-}" == "--discard-green-writes" ]] || {
  echo "该操作会切回冻结的旧数据库，使升级成功后的绿色库写入从生产中消失。" >&2
  echo "确认已理解并需要灾难回退时执行：$0 --discard-green-writes" >&2
  exit 2
}

exec 9>/run/lock/aether-cm-install.lock
flock -n 9 || fail '已有 Aether 安装或回退任务运行中'

set -a
# shellcheck disable=SC1090
source "${STATE_FILE}"
set +a

[[ "${PHASE:-}" == "complete" || "${PHASE:-}" == "committed_entry_closed" ]] || \
  fail "最近一次成功蓝绿升级状态不可回退：${PHASE:-unknown}"
: "${OLD_TARGET:?状态文件缺少 OLD_TARGET}"
: "${OLD_ENV_COPY:?状态文件缺少 OLD_ENV_COPY}"
: "${OLD_DATABASE_NAME:?状态文件缺少 OLD_DATABASE_NAME}"
: "${GREEN_DATABASE_NAME:?状态文件缺少 GREEN_DATABASE_NAME}"
: "${NEW_TARGET:?状态文件缺少 NEW_TARGET}"
: "${EDGE_SERVICE:?状态文件缺少 EDGE_SERVICE}"
: "${INSTALL_ROOT:?状态文件缺少 INSTALL_ROOT}"
: "${ENV_FILE:?状态文件缺少 ENV_FILE}"
: "${SERVICE:?状态文件缺少 SERVICE}"

[[ -d "${OLD_TARGET}" ]] || fail "旧 release 不存在：${OLD_TARGET}"
[[ -s "${OLD_ENV_COPY}" ]] || fail "旧环境备份不存在：${OLD_ENV_COPY}"
[[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${NEW_TARGET}" ]] || \
  fail '当前 release 已变化，拒绝基于过期状态自动回退'
[[ "${OLD_DATABASE_NAME}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]] || fail '旧数据库名不安全'

set -a
# shellcheck disable=SC1090
source "${OLD_ENV_COPY}"
set +a
OLD_DATABASE_URL="${AETHER_DATABASE_URL:-${AETHER_GATEWAY_DATA_POSTGRES_URL:-${DATABASE_URL:-}}}"
[[ "${OLD_DATABASE_URL}" == postgres://* || "${OLD_DATABASE_URL}" == postgresql://* ]] || \
  fail '旧环境中的 PostgreSQL URL 无效'
base="${OLD_DATABASE_URL%%\?*}"
query=""
[[ "${OLD_DATABASE_URL}" == *\?* ]] && query="?${OLD_DATABASE_URL#*\?}"
MAINTENANCE_URL="${base%/*}/postgres${query}"
APP_PORT="${APP_PORT:-8084}"
POSTGRES_ADMIN_URL="${AETHER_POSTGRES_ADMIN_URL:-}"

edge_was_active=0
if systemctl is-active --quiet "${EDGE_SERVICE}"; then
  edge_was_active=1
  log "停止 ${EDGE_SERVICE}，阻断回退窗口公网流量"
  systemctl stop "${EDGE_SERVICE}"
fi

log '停止当前 Aether'
systemctl stop "${SERVICE}"
systemctl is-active --quiet "${SERVICE}" && fail 'Aether 未能完全停止'

GREEN_ENV_COPY="${BACKUP_DIR}/aether-gateway.env.before-manual-rollback-$(date +%Y%m%d-%H%M%S)"
cp -a "${ENV_FILE}" "${GREEN_ENV_COPY}"
set -a
# shellcheck disable=SC1090
source "${GREEN_ENV_COPY}"
set +a
GREEN_DATABASE_URL="${AETHER_DATABASE_URL:-${AETHER_GATEWAY_DATA_POSTGRES_URL:-${DATABASE_URL:-}}}"
[[ "${GREEN_DATABASE_URL}" == postgres://* || "${GREEN_DATABASE_URL}" == postgresql://* ]] || \
  fail '当前绿色数据库 URL 无效；入口保持关闭'
GREEN_DUMP="${BACKUP_DIR}/green-before-manual-rollback-$(date +%Y%m%d-%H%M%S).dump"
log "备份绿色数据库后再切回旧库：${GREEN_DUMP}"
pg_dump --format=custom --compress=6 --no-owner --no-acl --file="${GREEN_DUMP}" "${GREEN_DATABASE_URL}"
sha256sum "${GREEN_DUMP}" > "${GREEN_DUMP}.sha256"

log "重新开放旧数据库：${OLD_DATABASE_NAME}"
if [[ -n "${POSTGRES_ADMIN_URL}" ]]; then
  admin_psql=(psql "${POSTGRES_ADMIN_URL}" -X -v ON_ERROR_STOP=1)
elif runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
  admin_psql=(runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d postgres)
else
  admin_psql=(psql "${MAINTENANCE_URL}" -X -v ON_ERROR_STOP=1)
fi
"${admin_psql[@]}" -v db="${OLD_DATABASE_NAME}" <<'SQL' >/dev/null
SELECT format('ALTER DATABASE %I ALLOW_CONNECTIONS true', :'db') \gexec
SQL

log '恢复旧环境和旧 release'
cp -a "${OLD_ENV_COPY}" "${ENV_FILE}.rollback"
mv -Tf "${ENV_FILE}.rollback" "${ENV_FILE}"
ln -sfn "${OLD_TARGET}" "${INSTALL_ROOT}/current.rollback"
mv -Tf "${INSTALL_ROOT}/current.rollback" "${INSTALL_ROOT}/current"

log '启动旧版本并验证健康状态'
systemctl start "${SERVICE}"
healthy=0
for _ in $(seq 1 120); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1 &&
     curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/readyz" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
[[ "${healthy}" == "1" ]] || fail '旧版本已启动但健康检查未通过；入口保持关闭'

if [[ "${edge_was_active}" == "1" || "${EDGE_WAS_ACTIVE:-0}" == "1" ]]; then
  systemctl start "${EDGE_SERVICE}"
  systemctl is-active --quiet "${EDGE_SERVICE}" || fail "${EDGE_SERVICE} 恢复失败"
fi

sed -i 's/^PHASE=.*/PHASE=manual_rollback_complete/' "${STATE_FILE}"
log "人工蓝绿回退完成；绿色数据库保留未删除：${GREEN_DATABASE_NAME}"
