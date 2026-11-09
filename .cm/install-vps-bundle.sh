#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly INSTALL_ROOT="${INSTALL_ROOT:-/opt/aether}"
readonly ENV_FILE="${AETHER_ENV_FILE:-/etc/aether/aether-gateway.env}"
readonly SERVICE="${AETHER_SERVICE:-aether-gateway}"
readonly BUNDLE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly RUN_ID="$(date +%Y%m%d-%H%M%S)"
readonly VERSION_NAME="$(basename "${BUNDLE_ROOT}")"
readonly RELEASE="${INSTALL_ROOT}/releases/${VERSION_NAME}-${RUN_ID}"
readonly BACKUP_DIR="/root/aether-backups/blue-green-${VERSION_NAME}-${RUN_ID}"
readonly OLD_TARGET="$(readlink -f "${INSTALL_ROOT}/current")"
readonly PROGRESS_BASE="${AETHER_PROGRESS_BASE:-0}"
readonly PROGRESS_SPAN="${AETHER_PROGRESS_SPAN:-100}"
readonly STATE_FILE="/root/aether-blue-green-run-${RUN_ID}.env"
readonly LAST_SUCCESS_STATE="/root/aether-blue-green-last-success.env"
readonly EDGE_SERVICE="${AETHER_EDGE_SERVICE:-nginx}"

CUTOVER_STARTED=0
OLD_DB_FROZEN=0
ROLLBACK_RUNNING=0
OLD_DATABASE_URL=""
OLD_DATABASE_NAME=""
MAINTENANCE_URL=""
POSTGRES_ADMIN_MODE=""
POSTGRES_ADMIN_URL="${AETHER_POSTGRES_ADMIN_URL:-}"
GREEN_DATABASE_NAME=""
GREEN_DATABASE_URL=""
REHEARSAL_DATABASE_NAME=""
OLD_ENV_COPY=""
APP_PORT=""
EDGE_WAS_ACTIVE=0

progress() {
  local raw_percent="$1"
  shift
  local mapped_percent=$(( PROGRESS_BASE + raw_percent * PROGRESS_SPAN / 100 ))
  (( mapped_percent > 100 )) && mapped_percent=100
  printf '[%s] [%3s%%] %s\n' "$(date '+%F %T')" "${mapped_percent}" "$*"
}

write_state() {
  local phase="$1"
  umask 077
  {
    printf 'PHASE=%q\n' "${phase}"
    printf 'RUN_ID=%q\n' "${RUN_ID}"
    printf 'OLD_TARGET=%q\n' "${OLD_TARGET}"
    printf 'OLD_ENV_COPY=%q\n' "${OLD_ENV_COPY}"
    printf 'OLD_DATABASE_NAME=%q\n' "${OLD_DATABASE_NAME}"
    printf 'GREEN_DATABASE_NAME=%q\n' "${GREEN_DATABASE_NAME}"
    printf 'NEW_TARGET=%q\n' "${RELEASE}"
    printf 'EDGE_SERVICE=%q\n' "${EDGE_SERVICE}"
    printf 'EDGE_WAS_ACTIVE=%q\n' "${EDGE_WAS_ACTIVE}"
    printf 'BACKUP_DIR=%q\n' "${BACKUP_DIR}"
    printf 'INSTALL_ROOT=%q\n' "${INSTALL_ROOT}"
    printf 'ENV_FILE=%q\n' "${ENV_FILE}"
    printf 'SERVICE=%q\n' "${SERVICE}"
    printf 'UPDATED_AT=%q\n' "$(date --iso-8601=seconds)"
  } > "${STATE_FILE}.new"
  mv -Tf "${STATE_FILE}.new" "${STATE_FILE}"
}

publish_last_success_state() {
  cp -a "${STATE_FILE}" "${LAST_SUCCESS_STATE}.new"
  chmod 0600 "${LAST_SUCCESS_STATE}.new"
  mv -Tf "${LAST_SUCCESS_STATE}.new" "${LAST_SUCCESS_STATE}"
}

health_ready() {
  curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1 &&
    curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/readyz" >/dev/null 2>&1
}

replace_database_name() {
  local url="$1"
  local database_name="$2"
  local base="${url%%\?*}"
  local query=""
  if [[ "${url}" == *\?* ]]; then
    query="?${url#*\?}"
  fi
  [[ "${base}" == postgres://* || "${base}" == postgresql://* ]]
  printf '%s/%s%s\n' "${base%/*}" "${database_name}" "${query}"
}

set_database_connections() {
  local database_name="$1"
  local allowed="$2"
  admin_psql -v db="${database_name}" \
    -v allowed="${allowed}" <<'SQL' >/dev/null
SELECT format('ALTER DATABASE %I ALLOW_CONNECTIONS %s', :'db', :'allowed') \gexec
SQL
}

terminate_database_connections() {
  local database_name="$1"
  admin_psql -v db="${database_name}" -Atq <<'SQL' >/dev/null
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'db' AND pid <> pg_backend_pid();
SQL
}

drop_database_if_exists() {
  local database_name="$1"
  if admin_psql -v db="${database_name}" -Atq <<'SQL' | grep -qx 1; then
SELECT 1 FROM pg_database WHERE datname = :'db';
SQL
    if [[ "${POSTGRES_ADMIN_MODE}" == "peer" ]]; then
      runuser -u postgres -- dropdb --force "${database_name}"
    else
      dropdb --force --maintenance-db="${POSTGRES_ADMIN_URL}" "${database_name}"
    fi
  fi
}

create_database() {
  local database_name="$1"
  local owner="$2"
  if [[ "${POSTGRES_ADMIN_MODE}" == "peer" ]]; then
    runuser -u postgres -- createdb --owner="${owner}" "${database_name}"
  else
    createdb --maintenance-db="${POSTGRES_ADMIN_URL}" --owner="${owner}" "${database_name}"
  fi
}

admin_psql() {
  if [[ "${POSTGRES_ADMIN_MODE}" == "peer" ]]; then
    runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d postgres "$@"
  else
    psql "${POSTGRES_ADMIN_URL}" -X -v ON_ERROR_STOP=1 "$@"
  fi
}

run_new_binary_for_database() {
  local database_url="$1"
  shift
  env \
    AETHER_DATABASE_DRIVER=postgres \
    AETHER_DATABASE_URL="${database_url}" \
    AETHER_GATEWAY_DATA_POSTGRES_URL="${database_url}" \
    DATABASE_URL="${database_url}" \
    "${RELEASE}/bin/aether-gateway" "$@"
}

table_exists() {
  local database_url="$1"
  local table_name="$2"
  [[ "$(psql "${database_url}" -X -v ON_ERROR_STOP=1 -v table_name="${table_name}" -Atq <<'SQL'
SELECT to_regclass('public.' || :'table_name') IS NOT NULL;
SQL
  )" == "t" ]]
}

capture_asset_baseline() {
  local database_url="$1"
  local output="$2"
  : > "${output}"
  local table_name
  for table_name in \
    users api_keys providers provider_api_keys provider_endpoints endpoints \
    wallets wallet_transactions payment_orders refund_requests user_groups \
    user_group_members models global_models system_configs; do
    if table_exists "${database_url}" "${table_name}"; then
      if [[ "${table_name}" == "user_group_members" ]]; then
        psql "${database_url}" -X -v ON_ERROR_STOP=1 -AtF $'\t' >> "${output}" <<SQL
SELECT '${table_name}', count(*)::text,
       COALESCE(md5(string_agg(row_hash, ',' ORDER BY row_hash)), '-')
FROM (
  SELECT md5(row_to_json(source_row)::text) AS row_hash
  FROM public."${table_name}" AS source_row
) AS row_hashes;
SQL
      else
        psql "${database_url}" -X -v ON_ERROR_STOP=1 -AtF $'\t' >> "${output}" <<SQL
SELECT '${table_name}', count(*)::text,
       COALESCE(md5(string_agg(id::text, ',' ORDER BY id::text)), '-')
FROM public."${table_name}";
SQL
      fi
    fi
  done
}

capture_financial_baseline() {
  local database_url="$1"
  local output="$2"
  psql "${database_url}" -X -v ON_ERROR_STOP=1 -AtF $'\t' <<'SQL' > "${output}"
SELECT count(*)::text,
       COALESCE(sum(balance), 0)::text,
       COALESCE(sum(gift_balance), 0)::text,
       COALESCE(sum(total_recharged), 0)::text,
       COALESCE(sum(total_consumed), 0)::text,
       COALESCE(sum(total_refunded), 0)::text,
       COALESCE(sum(total_adjusted), 0)::text
FROM public.wallets;
SQL
}

update_environment_database_url() {
  local target_url="$1"
  local temp_file="${BACKUP_DIR}/aether-gateway.env.new"
  local escaped_url="${target_url//\\/\\\\}"
  escaped_url="${escaped_url//\"/\\\"}"
  escaped_url="${escaped_url//\$/\\\$}"
  escaped_url="${escaped_url//\`/\\\`}"
  local encoded_url="\"${escaped_url}\""
  AETHER_ENCODED_DATABASE_URL="${encoded_url}" awk '
    BEGIN { a=0; g=0; d=0; url=ENVIRON["AETHER_ENCODED_DATABASE_URL"] }
    /^AETHER_DATABASE_URL=/ { print "AETHER_DATABASE_URL=" url; a=1; next }
    /^AETHER_GATEWAY_DATA_POSTGRES_URL=/ { print "AETHER_GATEWAY_DATA_POSTGRES_URL=" url; g=1; next }
    /^DATABASE_URL=/ { print "DATABASE_URL=" url; d=1; next }
    { print }
    END {
      if (!a) print "AETHER_DATABASE_URL=" url
      if (!g) print "AETHER_GATEWAY_DATA_POSTGRES_URL=" url
      if (!d) print "DATABASE_URL=" url
    }
  ' "${OLD_ENV_COPY}" > "${temp_file}"
  chmod --reference="${ENV_FILE}" "${temp_file}"
  chown --reference="${ENV_FILE}" "${temp_file}"
  mv -Tf "${temp_file}" "${ENV_FILE}"
}

restore_old_environment_and_release() {
  cp -a "${OLD_ENV_COPY}" "${ENV_FILE}.rollback"
  mv -Tf "${ENV_FILE}.rollback" "${ENV_FILE}"
  ln -sfn "${OLD_TARGET}" "${INSTALL_ROOT}/current.rollback"
  mv -Tf "${INSTALL_ROOT}/current.rollback" "${INSTALL_ROOT}/current"
  [[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${OLD_TARGET}" ]]
  cmp -s "${ENV_FILE}" "${OLD_ENV_COPY}"
}

rollback() {
  local exit_code="${1:-1}"
  if [[ "${ROLLBACK_RUNNING}" == "1" ]]; then
    exit "${exit_code}"
  fi
  ROLLBACK_RUNNING=1
  trap - ERR INT TERM
  set +e
  progress 100 "升级失败，退出码 ${exit_code}"
  write_state rollback_started

  if [[ "${CUTOVER_STARTED}" == "1" ]]; then
    if [[ "${EDGE_WAS_ACTIVE}" == "1" ]]; then
      systemctl stop "${EDGE_SERVICE}"
      if systemctl is-active --quiet "${EDGE_SERVICE}"; then
        progress 100 "严重错误：无法关闭 ${EDGE_SERVICE}；停止自动回退以避免切库期间接入请求"
        write_state rollback_blocked_edge_running
        exit "${exit_code}"
      fi
    fi
    systemctl stop "${SERVICE}"
    if systemctl is-active --quiet "${SERVICE}"; then
      progress 100 '严重错误：无法停止新版本；保持现场并停止自动处理'
      write_state rollback_blocked_service_running
      exit "${exit_code}"
    fi

    if ! restore_old_environment_and_release; then
      progress 100 '严重错误：旧环境或旧 release 恢复失败；Aether 保持停止'
      write_state rollback_blocked_release_restore
      exit "${exit_code}"
    fi

    if [[ "${OLD_DB_FROZEN}" == "1" ]]; then
      if ! set_database_connections "${OLD_DATABASE_NAME}" true; then
        progress 100 '严重错误：无法重新开放旧数据库；Aether 保持停止'
        write_state rollback_blocked_database_enable
        exit "${exit_code}"
      fi
      OLD_DB_FROZEN=0
    fi

    if ! systemctl start "${SERVICE}"; then
      progress 100 '旧版本启动失败；Aether 保持停止，请检查持久状态文件'
      write_state rollback_blocked_old_start
      exit "${exit_code}"
    fi
    local healthy=0
    for _ in $(seq 1 60); do
      if health_ready; then healthy=1; break; fi
      sleep 2
    done
    if [[ "${healthy}" != "1" ]]; then
      progress 100 '旧版本已恢复但健康检查失败，请人工处理'
      write_state rollback_blocked_old_unhealthy
      exit "${exit_code}"
    fi
    if [[ "${EDGE_WAS_ACTIVE}" == "1" ]] && ! systemctl start "${EDGE_SERVICE}"; then
      progress 100 "旧版已恢复健康，但 ${EDGE_SERVICE} 恢复失败，请人工启动入口服务"
      write_state rollback_blocked_edge_start
      exit "${exit_code}"
    fi
    progress 100 "已切回旧程序和未迁移的旧数据库；失败新库保留：${GREEN_DATABASE_NAME}"
    write_state rollback_complete
  else
    progress 100 '尚未开始生产切换，在线 Aether 未受影响'
    write_state failed_before_cutover
  fi
  exit "${exit_code}"
}

trap 'rollback "$?"' ERR
trap 'rollback 130' INT TERM

exec 9>/run/lock/aether-cm-install.lock
flock -n 9 || { progress 0 '已有 Aether 安装任务正在运行'; exit 1; }

[[ "$(id -u)" == "0" ]]
[[ "$(uname -m)" == "x86_64" ]]
for command_name in createdb curl dropdb file flock pg_dump pg_restore psql runuser sha256sum systemctl tar; do
  command -v "${command_name}" >/dev/null 2>&1 || { progress 0 "缺少命令：${command_name}"; false; }
done
[[ -x "${BUNDLE_ROOT}/bin/aether-gateway" ]]
[[ -f "${BUNDLE_ROOT}/frontend/index.html" ]]
[[ -f "${BUNDLE_ROOT}/BUILD_INFO" ]]
[[ -f "${ENV_FILE}" ]]
[[ -d "${OLD_TARGET}" ]]
systemctl is-active --quiet "${SERVICE}"

set -a
source "${ENV_FILE}"
set +a
OLD_DATABASE_URL="${AETHER_DATABASE_URL:-${AETHER_GATEWAY_DATA_POSTGRES_URL:-${DATABASE_URL:-}}}"
: "${OLD_DATABASE_URL:?PostgreSQL database URL is not configured}"
[[ "${OLD_DATABASE_URL}" == postgres://* || "${OLD_DATABASE_URL}" == postgresql://* ]]
APP_PORT="${APP_PORT:-8084}"
OLD_DATABASE_NAME="$(psql "${OLD_DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc 'SELECT current_database()')"
readonly DATABASE_OWNER="$(psql "${OLD_DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc 'SELECT current_user')"
[[ "${OLD_DATABASE_NAME}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]
[[ "${DATABASE_OWNER}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]
MAINTENANCE_URL="$(replace_database_name "${OLD_DATABASE_URL}" postgres)"
if [[ -n "${POSTGRES_ADMIN_URL}" ]]; then
  POSTGRES_ADMIN_MODE=url
  [[ "${POSTGRES_ADMIN_URL}" == postgres://* || "${POSTGRES_ADMIN_URL}" == postgresql://* ]]
elif runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
  POSTGRES_ADMIN_MODE=peer
else
  POSTGRES_ADMIN_MODE=url
  POSTGRES_ADMIN_URL="${MAINTENANCE_URL}"
fi
GREEN_DATABASE_NAME="aether_green_${RUN_ID//-/_}"
REHEARSAL_DATABASE_NAME="aether_rehearsal_${RUN_ID//-/_}"
GREEN_DATABASE_URL="$(replace_database_name "${OLD_DATABASE_URL}" "${GREEN_DATABASE_NAME}")"
readonly REHEARSAL_DATABASE_URL="$(replace_database_name "${OLD_DATABASE_URL}" "${REHEARSAL_DATABASE_NAME}")"

progress 2 '执行构建包、数据库权限和磁盘预检'
EXPECTED_BUILD_SHA="${VERSION_NAME#aether-cm-}"
EXPECTED_BUILD_SHA="${EXPECTED_BUILD_SHA%-linux-amd64}"
[[ "${EXPECTED_BUILD_SHA}" =~ ^[0-9a-f]{40}$ ]]
grep -qx "git_sha=${EXPECTED_BUILD_SHA}" "${BUNDLE_ROOT}/BUILD_INFO" || {
  progress 2 'BUILD_INFO 与包目录提交不一致'; false;
}
(cd "${BUNDLE_ROOT}" && sha256sum --check bin/aether-gateway.sha256)
"${BUNDLE_ROOT}/bin/aether-gateway" --help >/dev/null
psql "${OLD_DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc 'SELECT 1' >/dev/null
admin_psql -Atqc 'SELECT 1' >/dev/null
database_size="$(psql "${OLD_DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc 'SELECT pg_database_size(current_database())')"
available_bytes="$(( $(df -Pk /root | awk 'NR==2 {print $4}') * 1024 ))"
required_bytes="$(( database_size * 3 + 2 * 1024 * 1024 * 1024 ))"
(( available_bytes >= required_bytes )) || {
  progress 2 "空间不足：需要至少 ${required_bytes} bytes，当前 ${available_bytes} bytes"; false;
}

progress 6 "安装只读 release：${RELEASE}"
install -d -m 0755 -o root -g root "${RELEASE}/bin" "${RELEASE}/frontend"
install -m 0555 -o root -g root "${BUNDLE_ROOT}/bin/aether-gateway" "${RELEASE}/bin/aether-gateway"
install -m 0500 -o root -g root "${BUNDLE_ROOT}/rollback-vps-blue-green.sh" \
  /root/aether-blue-green-rollback.sh
cp -a "${BUNDLE_ROOT}/frontend/." "${RELEASE}/frontend/"
chown -R root:root "${RELEASE}"
find "${RELEASE}/frontend" -type d -exec chmod 0555 {} +
find "${RELEASE}/frontend" -type f -exec chmod 0444 {} +
"${RELEASE}/bin/aether-gateway" --help >/dev/null

progress 10 '备份配置并创建在线迁移演练快照'
install -d -m 0700 "${BACKUP_DIR}"
OLD_ENV_COPY="${BACKUP_DIR}/aether-gateway.env.before"
cp -a "${ENV_FILE}" "${OLD_ENV_COPY}"
tar --acls --xattrs --numeric-owner -C /etc -czf "${BACKUP_DIR}/aether-config.tar.gz" aether
systemctl cat "${SERVICE}.service" > "${BACKUP_DIR}/${SERVICE}.service.txt"
printf '%s\n' "${OLD_TARGET}" > "${BACKUP_DIR}/old-release.txt"
pg_dump --format=custom --compress=6 --no-owner --no-acl \
  --file="${BACKUP_DIR}/rehearsal.dump" "${OLD_DATABASE_URL}"
pg_restore --list "${BACKUP_DIR}/rehearsal.dump" > "${BACKUP_DIR}/rehearsal.list"

progress 18 "恢复演练数据库：${REHEARSAL_DATABASE_NAME}"
drop_database_if_exists "${REHEARSAL_DATABASE_NAME}"
create_database "${REHEARSAL_DATABASE_NAME}" "${DATABASE_OWNER}"
pg_restore --no-owner --no-acl --exit-on-error --single-transaction \
  --dbname="${REHEARSAL_DATABASE_URL}" "${BACKUP_DIR}/rehearsal.dump"
run_new_binary_for_database "${REHEARSAL_DATABASE_URL}" --migrate
run_new_binary_for_database "${REHEARSAL_DATABASE_URL}" --apply-backfills
[[ "$(psql "${REHEARSAL_DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc \
  "SELECT count(*) FROM pg_index WHERE NOT indisvalid")" == "0" ]]
[[ "$(psql "${REHEARSAL_DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc \
  'SELECT count(*) FROM public._sqlx_migrations WHERE NOT success')" == "0" ]]
drop_database_if_exists "${REHEARSAL_DATABASE_NAME}"
REHEARSAL_DATABASE_NAME=""
progress 35 '隔离数据库迁移演练成功；即将进入生产维护窗口'

CUTOVER_STARTED=1
if systemctl is-active --quiet "${EDGE_SERVICE}"; then
  EDGE_WAS_ACTIVE=1
fi
write_state stopping_old_service
if [[ "${EDGE_WAS_ACTIVE}" == "1" ]]; then
  progress 36 "停止 ${EDGE_SERVICE}，验证完成前阻断公网流量"
  systemctl stop "${EDGE_SERVICE}"
  systemctl is-active --quiet "${EDGE_SERVICE}" && { progress 36 "${EDGE_SERVICE} 未能完全停止"; false; }
fi
systemctl stop "${SERVICE}"
systemctl is-active --quiet "${SERVICE}" && { progress 36 'Aether 未能完全停止'; false; }

progress 40 '服务已停止，记录最终资产基线和一致快照'
capture_asset_baseline "${OLD_DATABASE_URL}" "${BACKUP_DIR}/assets.before.tsv"
capture_financial_baseline "${OLD_DATABASE_URL}" "${BACKUP_DIR}/financial.before.tsv"
psql "${OLD_DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc \
  'SELECT version, description, success FROM public._sqlx_migrations ORDER BY version' \
  > "${BACKUP_DIR}/sqlx-migrations.before.tsv"
pg_dump --format=custom --compress=6 --no-owner --no-acl \
  --file="${BACKUP_DIR}/aether-final.dump" "${OLD_DATABASE_URL}"
pg_restore --list "${BACKUP_DIR}/aether-final.dump" > "${BACKUP_DIR}/aether-final.list"
(cd "${BACKUP_DIR}" && sha256sum aether-final.dump aether-config.tar.gz > SHA256SUMS)

progress 48 '冻结旧数据库，保证它是不可变的回退锚点'
set_database_connections "${OLD_DATABASE_NAME}" false
OLD_DB_FROZEN=1
terminate_database_connections "${OLD_DATABASE_NAME}"
write_state old_database_frozen

progress 52 "创建绿色数据库：${GREEN_DATABASE_NAME}"
drop_database_if_exists "${GREEN_DATABASE_NAME}"
create_database "${GREEN_DATABASE_NAME}" "${DATABASE_OWNER}"
pg_restore --no-owner --no-acl --exit-on-error --single-transaction \
  --dbname="${GREEN_DATABASE_URL}" "${BACKUP_DIR}/aether-final.dump"

progress 60 '在绿色数据库执行 schema migration 和 backfill'
run_new_binary_for_database "${GREEN_DATABASE_URL}" --migrate
run_new_binary_for_database "${GREEN_DATABASE_URL}" --apply-backfills
[[ "$(psql "${GREEN_DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc \
  "SELECT count(*) FROM pg_index WHERE NOT indisvalid")" == "0" ]]
[[ "$(psql "${GREEN_DATABASE_URL}" -X -v ON_ERROR_STOP=1 -Atqc \
  'SELECT count(*) FROM public._sqlx_migrations WHERE NOT success')" == "0" ]]

progress 70 '切换环境、release 并启动新版本'
update_environment_database_url "${GREEN_DATABASE_URL}"
ln -sfn "${RELEASE}" "${INSTALL_ROOT}/current.new"
mv -Tf "${INSTALL_ROOT}/current.new" "${INSTALL_ROOT}/current"
[[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${RELEASE}" ]]
write_state starting_new_service
systemctl start "${SERVICE}"

progress 75 '等待新版本健康检查（最长 20 分钟）'
healthy=0
deadline=$(( $(date +%s) + 1200 ))
while (( $(date +%s) < deadline )); do
  if health_ready; then healthy=1; break; fi
  systemctl is-active --quiet "${SERVICE}" || false
  sleep 3
done
[[ "${healthy}" == "1" ]]
[[ "$(readlink -f "${INSTALL_ROOT}/current")" == "${RELEASE}" ]]

progress 82 '验证资产主键集合、钱包总额和迁移状态'
capture_asset_baseline "${GREEN_DATABASE_URL}" "${BACKUP_DIR}/assets.after.tsv"
capture_financial_baseline "${GREEN_DATABASE_URL}" "${BACKUP_DIR}/financial.after.tsv"
diff -u "${BACKUP_DIR}/assets.before.tsv" "${BACKUP_DIR}/assets.after.tsv"
diff -u "${BACKUP_DIR}/financial.before.tsv" "${BACKUP_DIR}/financial.after.tsv"

progress 88 '严格验证伪造管理员身份头被认证层拒绝'
forged_status="$({ curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'x-aether-gateway: rust-phase3' \
  -H 'x-aether-admin-user-id: 00000000-0000-0000-0000-000000000001' \
  -H 'x-aether-admin-user-role: admin' \
  -H 'x-aether-admin-session-id: cm-blue-green-verification' \
  "http://127.0.0.1:${APP_PORT}/api/admin/users"; } || true)"
[[ "${forged_status}" == "401" || "${forged_status}" == "403" ]]

progress 91 '持续观察 90 秒，确认服务 PID、健康和数据库连接稳定'
stable_pid="$(systemctl show -p MainPID --value "${SERVICE}")"
[[ "${stable_pid}" =~ ^[1-9][0-9]*$ ]]
for attempt in $(seq 1 18); do
  sleep 5
  systemctl is-active --quiet "${SERVICE}"
  health_ready
  [[ "$(systemctl show -p MainPID --value "${SERVICE}")" == "${stable_pid}" ]]
  progress "$(( 91 + attempt * 7 / 18 ))" "稳定性检查（${attempt}/18）"
done

progress 99 '新版本验证通过；提交绿色数据库，停止自动旧库回退'
CUTOVER_STARTED=0
trap - ERR INT TERM
write_state committed_entry_closed
publish_last_success_state
cat > "${BACKUP_DIR}/RESULT.txt" <<EOF
status=success
release=${RELEASE}
old_release=${OLD_TARGET}
old_database=${OLD_DATABASE_NAME}
green_database=${GREEN_DATABASE_NAME}
backup=${BACKUP_DIR}/aether-final.dump
completed_at=$(date --iso-8601=seconds)
EOF
chmod 0600 "${BACKUP_DIR}/RESULT.txt"
if [[ "${EDGE_WAS_ACTIVE}" == "1" ]]; then
  if ! systemctl start "${EDGE_SERVICE}" || ! systemctl is-active --quiet "${EDGE_SERVICE}"; then
    progress 100 "绿色版本已提交且健康，但 ${EDGE_SERVICE} 启动失败；为避免数据丢失，不自动切回旧库"
    progress 100 "修复入口后执行：systemctl start ${EDGE_SERVICE}"
    exit 1
  fi
fi
write_state complete
publish_last_success_state
progress 100 "蓝绿升级完成：${RELEASE}"
progress 100 "旧数据库回退锚点（禁止删除）：${OLD_DATABASE_NAME}"
progress 100 "绿色生产数据库：${GREEN_DATABASE_NAME}"
progress 100 "最终一致快照：${BACKUP_DIR}/aether-final.dump"
