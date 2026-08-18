#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/opt/aether}"
ENV_FILE="${AETHER_ENV_FILE:-/etc/aether/aether-gateway.env}"
SERVICE="${AETHER_SERVICE:-aether-gateway}"
BUNDLE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
VERSION_NAME="$(basename "${BUNDLE_ROOT}")"
RELEASE="${INSTALL_ROOT}/releases/${VERSION_NAME}-${RUN_ID}"
BACKUP_DIR="/root/aether-backups/pre-${VERSION_NAME}-${RUN_ID}"
OLD_TARGET="$(readlink -f "${INSTALL_ROOT}/current")"
CUTOVER_STARTED=0
DATABASE_BACKUP_READY=0

progress() {
  local percent="$1"
  shift
  printf '[%s] [%3s%%] %s\n' "$(date '+%F %T')" "${percent}" "$*"
}

rollback() {
  local exit_code=$?
  trap - ERR
  progress 100 "安装失败，退出码 ${exit_code}"

  if [[ "${CUTOVER_STARTED}" == "1" ]]; then
    progress 100 "正在回滚到 ${OLD_TARGET}"
    systemctl stop "${SERVICE}" || true
    ln -sfn "${OLD_TARGET}" "${INSTALL_ROOT}/current.rollback"
    mv -Tf "${INSTALL_ROOT}/current.rollback" "${INSTALL_ROOT}/current"

    if [[ "${DATABASE_BACKUP_READY}" == "1" ]]; then
      progress 100 "正在恢复切换前 PostgreSQL 快照"
      pg_restore \
        --clean \
        --if-exists \
        --no-owner \
        --no-acl \
        --dbname="${DATABASE_URL}" \
        "${BACKUP_DIR}/aether-postgres.dump" || true
    fi

    systemctl start "${SERVICE}" || true
    sleep 3
    systemctl is-active --quiet "${SERVICE}" || true
  fi

  progress 100 "数据库备份保留在 ${BACKUP_DIR}"
  exit "${exit_code}"
}

trap rollback ERR

exec 9>/run/lock/aether-cm-install.lock
flock -n 9 || {
  progress 0 '已有 Aether 安装任务正在运行'
  exit 1
}

[[ "$(id -u)" == "0" ]]
[[ "$(uname -m)" == "x86_64" ]]
[[ -x "${BUNDLE_ROOT}/bin/aether-gateway" ]]
[[ -f "${BUNDLE_ROOT}/frontend/index.html" ]]
[[ -f "${ENV_FILE}" ]]
[[ -d "${OLD_TARGET}" ]]
systemctl is-active --quiet "${SERVICE}"

set -a
source "${ENV_FILE}"
set +a
: "${DATABASE_URL:?DATABASE_URL is not configured}"
APP_PORT="${APP_PORT:-8084}"

progress 5 "备份 PostgreSQL 和环境配置"
install -d -m 0700 "${BACKUP_DIR}"
install -m 0600 "${ENV_FILE}" "${BACKUP_DIR}/aether-gateway.env"
pg_dump \
  --format=custom \
  --compress=6 \
  --no-owner \
  --no-acl \
  --file="${BACKUP_DIR}/aether-postgres.dump" \
  "${DATABASE_URL}"
chmod 0600 "${BACKUP_DIR}/aether-postgres.dump"
pg_restore --list "${BACKUP_DIR}/aether-postgres.dump" >/dev/null
DATABASE_BACKUP_READY=1

progress 35 "安装发布包到 ${RELEASE}"
install -d -m 2775 -o root -g aether "${RELEASE}/bin" "${RELEASE}/frontend"
install -m 0775 -o root -g aether \
  "${BUNDLE_ROOT}/bin/aether-gateway" \
  "${RELEASE}/bin/aether-gateway"
cp -a "${BUNDLE_ROOT}/frontend/." "${RELEASE}/frontend/"
chown -R root:aether "${RELEASE}"
find "${RELEASE}/frontend" -type d -exec chmod 0775 {} +
find "${RELEASE}/frontend" -type f -exec chmod 0664 {} +
"${RELEASE}/bin/aether-gateway" --help >/dev/null

progress 55 '停止 Aether 并原子切换版本'
CUTOVER_STARTED=1
systemctl stop "${SERVICE}"
ln -sfn "${RELEASE}" "${INSTALL_ROOT}/current.new"
mv -Tf "${INSTALL_ROOT}/current.new" "${INSTALL_ROOT}/current"
systemctl start "${SERVICE}"

progress 70 '等待健康检查'
healthy=0
for attempt in $(seq 1 45); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1 && \
     curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/readyz" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  progress 70 "等待 Aether 就绪（${attempt}/45）"
  sleep 2
done

[[ "${healthy}" == "1" ]]
systemctl is-active --quiet "${SERVICE}"
[[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${RELEASE}" ]]

progress 90 '验证伪造管理员请求已被应用拒绝'
forged_status="$({ curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'x-aether-gateway: rust-phase3' \
  -H 'x-aether-admin-user-id: 00000000-0000-0000-0000-000000000001' \
  -H 'x-aether-admin-user-role: admin' \
  -H 'x-aether-admin-session-id: update-verification' \
  "http://127.0.0.1:${APP_PORT}/api/admin/users"; } || true)"
if [[ "${forged_status}" =~ ^2 ]]; then
  progress 90 "安全验证失败：伪造管理员请求仍返回 ${forged_status}"
  false
fi
progress 95 "安全验证通过：伪造管理员请求返回 ${forged_status}"

CUTOVER_STARTED=0
progress 100 "更新完成：${RELEASE}"
progress 100 "数据库备份：${BACKUP_DIR}"
progress 100 "旧版本目录：${OLD_TARGET}"
