#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

INSTALL_ROOT="${INSTALL_ROOT:-/opt/aether}"
ENV_FILE="${AETHER_ENV_FILE:-/etc/aether/aether-gateway.env}"
SERVICE="${AETHER_SERVICE:-aether-gateway}"
BUNDLE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
VERSION_NAME="$(basename "${BUNDLE_ROOT}")"
RELEASE="${INSTALL_ROOT}/releases/${VERSION_NAME}-${RUN_ID}"
BACKUP_DIR="/root/aether-backups/pre-${VERSION_NAME}-${RUN_ID}"
OLD_TARGET="$(readlink -f "${INSTALL_ROOT}/current")"
PROGRESS_BASE="${AETHER_PROGRESS_BASE:-0}"
PROGRESS_SPAN="${AETHER_PROGRESS_SPAN:-100}"
CUTOVER_STARTED=0
DATABASE_BACKUP_READY=0
ROLLBACK_RUNNING=0

progress() {
  local raw_percent="$1"
  shift
  local mapped_percent=$(( PROGRESS_BASE + raw_percent * PROGRESS_SPAN / 100 ))
  (( mapped_percent > 100 )) && mapped_percent=100
  printf '[%s] [%3s%%] %s\n' "$(date '+%F %T')" "${mapped_percent}" "$*"
}

health_ready() {
  curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1 &&
    curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/readyz" >/dev/null 2>&1
}

restore_database_strict() {
  pg_restore \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    --exit-on-error \
    --single-transaction \
    --dbname="${DATABASE_URL}" \
    "${BACKUP_DIR}/aether-postgres.dump"
}

rollback() {
  local exit_code="${1:-1}"
  if [[ "${ROLLBACK_RUNNING}" == "1" ]]; then
    exit "${exit_code}"
  fi
  ROLLBACK_RUNNING=1
  trap - ERR INT TERM
  set +e

  progress 100 "安装失败，退出码 ${exit_code}"

  if [[ "${CUTOVER_STARTED}" == "1" ]]; then
    progress 100 "停止新版本并切回旧程序：${OLD_TARGET}"
    systemctl stop "${SERVICE}"
    if systemctl is-active --quiet "${SERVICE}"; then
      progress 100 "严重错误：无法停止 Aether；为保护数据库，不执行在线恢复"
      progress 100 "Aether 仍在运行，请交给外部 AI 人工处理"
      exit "${exit_code}"
    fi

    ln -sfn "${OLD_TARGET}" "${INSTALL_ROOT}/current.rollback"
    mv -Tf "${INSTALL_ROOT}/current.rollback" "${INSTALL_ROOT}/current"

    if [[ "${DATABASE_BACKUP_READY}" == "1" ]]; then
      progress 100 "严格恢复切换前 PostgreSQL 快照"
      if ! restore_database_strict; then
        progress 100 "严重错误：PostgreSQL 恢复失败；Aether 保持停止，禁止带着不确定数据启动"
        progress 100 "数据库快照：${BACKUP_DIR}/aether-postgres.dump"
        exit "${exit_code}"
      fi
      progress 100 "PostgreSQL 快照恢复成功"
    fi

    if ! systemctl start "${SERVICE}"; then
      progress 100 "旧版本启动失败，请交给外部 AI 检查"
      exit "${exit_code}"
    fi

    local rollback_healthy=0
    for _ in $(seq 1 30); do
      if health_ready; then
        rollback_healthy=1
        break
      fi
      sleep 2
    done
    if [[ "${rollback_healthy}" != "1" ]]; then
      progress 100 "旧版本已切回，但健康检查未通过，请交给外部 AI 检查"
      exit "${exit_code}"
    fi
    progress 100 "已完整回退到旧程序和切换前数据库"
  else
    progress 100 "尚未切换生产版本，在线 Aether 未受影响"
  fi

  progress 100 "备份保留在：${BACKUP_DIR}"
  exit "${exit_code}"
}

trap 'rollback "$?"' ERR
trap 'rollback 130' INT TERM

exec 9>/run/lock/aether-cm-install.lock
flock -n 9 || {
  progress 0 '已有 Aether 安装任务正在运行'
  exit 1
}

[[ "$(id -u)" == "0" ]]
[[ "$(uname -m)" == "x86_64" ]]

for command_name in curl flock pg_dump pg_restore psql sha256sum systemctl tar; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    progress 0 "缺少命令：${command_name}"
    false
  }
done

[[ -x "${BUNDLE_ROOT}/bin/aether-gateway" ]]
[[ -f "${BUNDLE_ROOT}/frontend/index.html" ]]
[[ -f "${ENV_FILE}" ]]
[[ -d "${OLD_TARGET}" ]]
systemctl is-active --quiet "${SERVICE}"

set -a
source "${ENV_FILE}"
set +a
: "${DATABASE_URL:?DATABASE_URL is not configured}"
[[ "${AETHER_DATABASE_DRIVER:-postgres}" == "postgres" ]]
APP_PORT="${APP_PORT:-8084}"

progress 3 "执行安装前检查"
"${BUNDLE_ROOT}/bin/aether-gateway" --help >/dev/null
psql "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc 'SELECT 1' >/dev/null

progress 8 "备份完整配置、systemd unit 和 PostgreSQL"
install -d -m 0700 "${BACKUP_DIR}"
tar --acls --xattrs --numeric-owner -C /etc -czf "${BACKUP_DIR}/aether-config.tar.gz" aether
systemctl cat "${SERVICE}.service" > "${BACKUP_DIR}/${SERVICE}.service.txt"
printf '%s\n' "${OLD_TARGET}" > "${BACKUP_DIR}/old-release.txt"

pg_dump \
  --format=custom \
  --compress=6 \
  --no-owner \
  --no-acl \
  --file="${BACKUP_DIR}/aether-postgres.dump" \
  "${DATABASE_URL}"
chmod 0600 "${BACKUP_DIR}/aether-postgres.dump"
pg_restore --list "${BACKUP_DIR}/aether-postgres.dump" > "${BACKUP_DIR}/aether-postgres.list"
(
  cd "${BACKUP_DIR}"
  sha256sum aether-postgres.dump aether-config.tar.gz > SHA256SUMS
)
DATABASE_BACKUP_READY=1

progress 25 "记录切换前资产类表基线"
: > "${BACKUP_DIR}/critical-table-counts.before.tsv"
for table_name in users api_keys providers provider_api_keys wallets wallet_transactions; do
  table_count="$(psql "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc "SELECT count(*) FROM public.${table_name}")"
  printf '%s\t%s\n' "${table_name}" "${table_count}" >> "${BACKUP_DIR}/critical-table-counts.before.tsv"
done
psql "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc \
  'SELECT version, description, success FROM public._sqlx_migrations ORDER BY version' \
  > "${BACKUP_DIR}/sqlx-migrations.before.tsv"

progress 35 "安装新 release：${RELEASE}"
install -d -m 2775 -o root -g aether "${RELEASE}/bin" "${RELEASE}/frontend"
install -m 0775 -o root -g aether \
  "${BUNDLE_ROOT}/bin/aether-gateway" \
  "${RELEASE}/bin/aether-gateway"
cp -a "${BUNDLE_ROOT}/frontend/." "${RELEASE}/frontend/"
chown -R root:aether "${RELEASE}"
find "${RELEASE}/frontend" -type d -exec chmod 0775 {} +
find "${RELEASE}/frontend" -type f -exec chmod 0664 {} +
"${RELEASE}/bin/aether-gateway" --help >/dev/null

progress 50 '停止 Aether 并原子切换版本'
CUTOVER_STARTED=1
systemctl stop "${SERVICE}"
if systemctl is-active --quiet "${SERVICE}"; then
  progress 50 'Aether 未能完全停止'
  false
fi
ln -sfn "${RELEASE}" "${INSTALL_ROOT}/current.new"
mv -Tf "${INSTALL_ROOT}/current.new" "${INSTALL_ROOT}/current"
systemctl start "${SERVICE}"

progress 63 '等待数据库迁移及健康检查'
healthy=0
for attempt in $(seq 1 300); do
  if health_ready; then
    healthy=1
    break
  fi
  if (( attempt == 1 || attempt % 5 == 0 )); then
    progress 63 "等待 Aether 就绪（${attempt}/300，最长 10 分钟）"
  fi
  sleep 2
done
[[ "${healthy}" == "1" ]]
systemctl is-active --quiet "${SERVICE}"
[[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${RELEASE}" ]]

progress 75 '验证数据库迁移和资产类表数量'
failed_migrations="$(psql "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc \
  'SELECT count(*) FROM public._sqlx_migrations WHERE NOT success')"
[[ "${failed_migrations}" == "0" ]]

: > "${BACKUP_DIR}/critical-table-counts.after.tsv"
while IFS=$'\t' read -r table_name before_count; do
  after_count="$(psql "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc "SELECT count(*) FROM public.${table_name}")"
  printf '%s\t%s\n' "${table_name}" "${after_count}" >> "${BACKUP_DIR}/critical-table-counts.after.tsv"
  if (( after_count < before_count )); then
    progress 75 "资产类表 ${table_name} 行数异常：${before_count} -> ${after_count}"
    false
  fi
done < "${BACKUP_DIR}/critical-table-counts.before.tsv"

progress 85 '持续观察 60 秒，确认服务没有崩溃或重启'
stable_pid="$(systemctl show -p MainPID --value "${SERVICE}")"
[[ "${stable_pid}" =~ ^[1-9][0-9]*$ ]]
for attempt in $(seq 1 12); do
  sleep 5
  systemctl is-active --quiet "${SERVICE}"
  health_ready
  current_pid="$(systemctl show -p MainPID --value "${SERVICE}")"
  [[ "${current_pid}" == "${stable_pid}" ]]
  progress "$(( 85 + attempt * 8 / 12 ))" "稳定性检查（${attempt}/12）"
done

progress 95 '验证伪造管理员身份头仍被拒绝'
forged_status="$({ curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'x-aether-gateway: rust-phase3' \
  -H 'x-aether-admin-user-id: 00000000-0000-0000-0000-000000000001' \
  -H 'x-aether-admin-user-role: admin' \
  -H 'x-aether-admin-session-id: official-update-verification' \
  "http://127.0.0.1:${APP_PORT}/api/admin/users"; } || true)"
if [[ "${forged_status}" =~ ^2 ]]; then
  progress 95 "安全验证失败：伪造管理员请求返回 ${forged_status}"
  false
fi

progress 98 "安装验证通过；伪造管理员请求返回 ${forged_status:-connection-error}"
CUTOVER_STARTED=0
trap - ERR INT TERM

progress 100 "官方源码版本安装完成：${RELEASE}"
progress 100 "PostgreSQL 与配置备份：${BACKUP_DIR}"
progress 100 "旧 release 保留：${OLD_TARGET}"
